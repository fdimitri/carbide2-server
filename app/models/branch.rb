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
  # Every head move is logged with a seq (the reflog).
  after_save :log_head

  validates :name, presence: true
  validates :name, uniqueness: { scope: :file_node_id, conditions: -> { live } }

  MAIN = 'main'

  # A content-head move: FOR SHARE on the project branch (the same row path
  # ops, snapshots, forks, and merges lock FOR UPDATE), then FOR UPDATE on
  # this line. A freeze then waits for in-flight content commits; a content
  # write waits for an in-flight freeze. Two content writers still SHARE
  # together.
  def self.lock_head!(id)
    pb_id, fn_id = unscoped.where(id: id).pick(:project_branch_id, :file_node_id)
    if pb_id
      ProjectBranch.lock("FOR SHARE").find(pb_id)
    elsif fn_id
      # Detached per-file line: still wait behind (and block) a freeze on any
      # live project branch of this file's project, so a cut at S cannot miss
      # an in-flight write.
      pid = FileNode.where(id: fn_id).pick(:project_id)
      ProjectBranch.live.where(project_id: pid).lock("FOR SHARE").to_a if pid
    end
    lock.find(id)
  end

  # A deleted branch keeps its row (revisions.branch_id must keep meaning "the
  # branch this was committed on", or a past project state changes — ADR-042).
  # It is hidden from lookups by FileNode#branches, and its name is reusable.
  scope :live,       -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }

  def deleted?
    deleted_at.present?
  end

  # Tombstone: stamped so a later recreate can reuse the name.
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
