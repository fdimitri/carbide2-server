# frozen_string_literal: true
class Branch < ApplicationRecord
  self.primary_key = 'id'

  belongs_to :file_node
  belongs_to :head, class_name: 'Revision', foreign_key: 'head_revision_id', optional: true
  belongs_to :project_branch, optional: true
  has_many :branch_heads, dependent: :delete_all

  before_validation :assign_id, on: :create
  # ADR-042: a branch is born at a seq; a project state cut before it does not
  # see it. Inside the insert's transaction, like Revision#stamp_seq.
  before_create :stamp_seq
  # Every head move is logged with a seq (the reflog): ProjectState reads
  # "head of b at S" from it. Runs inside the save's transaction.
  after_save :log_head

  validates :name, presence: true
  validates :name, uniqueness: { scope: :file_node_id, conditions: -> { live } }

  MAIN = 'main'

  # A deleted branch keeps its row (revisions.branch_id must keep meaning "the
  # branch this was committed on", or a past project state changes — ADR-042).
  # It is hidden from lookups by FileNode#branches, and its name is reusable.
  scope :live,       -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }

  def deleted?
    deleted_at.present?
  end

  # Was this branch live at project seq S?
  def live_at?(s)
    seq <= s && (deleted_seq.nil? || deleted_seq > s)
  end

  # Tombstone (ADR-042): stamped so a state cut before the deletion still
  # resolves through this branch.
  def tombstone!
    transaction do
      pid = FileNode.where(id: file_node_id).pick(:project_id)
      update!(deleted_at: Time.current, deleted_seq: DbfsV2::Clock.tick!(pid))
    end
  end

  def self.main_for(file_node_id)
    live.find_or_create_by!(file_node_id: file_node_id, name: MAIN)
  end

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end

  def project_id
    FileNode.where(id: file_node_id).pick(:project_id)
  end

  def stamp_seq
    return if seq.to_i.positive?
    self.seq = DbfsV2::Clock.tick!(project_id)
  end

  # A head that is a revision committed on this branch shares that revision's
  # seq (append: one tick per revision). A head pointed at foreign history
  # (fast-forward) is a move of its own and ticks.
  def log_head
    return unless head_revision_id && (previously_new_record? || saved_change_to_head_revision_id?)
    rev_seq, rev_branch = Revision.where(id: head_revision_id).pick(:seq, :branch_id)
    s = if previously_new_record?
          seq
        elsif rev_branch == id && rev_seq.to_i.positive?
          rev_seq
        else
          DbfsV2::Clock.tick!(project_id)
        end
    BranchHead.insert!({ branch_id: id, seq: s, revision_id: head_revision_id, created_at: Time.now.utc })
  end
end
