# A branch of the whole project (ADR-042): its own existence/identity log
# (file_events tagged with this row) and, for non-main branches, its own
# current path index (branch_entries). Identity is the uuid: a tombstoned name
# can be reused by a new row without reviving this one's history.
#
# `main` is a row too, so events and content branches have one owner model,
# but its index is file_nodes (Store's original code path), not branch_entries.
class ProjectBranch < ApplicationRecord
  self.primary_key = 'id'

  MAIN = Branch::MAIN

  belongs_to :forked_from, class_name: 'ProjectBranch', optional: true
  has_many :entries, class_name: 'BranchEntry', dependent: :delete_all
  has_many :file_events
  has_many :content_branches, class_name: 'Branch'

  before_validation :assign_id, on: :create
  before_create :stamp_seq

  validates :name, presence: true

  scope :live,       -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }

  def self.main_for(project_id)
    live.find_or_create_by!(project_id: project_id, name: MAIN) { |b| b.seq = 0 }
  end

  def main?    = name == MAIN && forked_from_id.nil?
  def deleted? = deleted_at.present?

  def live_at?(s)
    seq <= s && (deleted_seq.nil? || deleted_seq > s)
  end

  # [[branch, cut], ...] from self back to main: self's log up to `s`, then
  # each ancestor's up to the seq the child forked at. A state at (s, self)
  # is the fold of exactly these slices, in reverse order.
  def lineage(s)
    chain = []
    b, cut = self, s
    while b
      chain << [b, cut]
      cut = [cut, b.fork_seq].compact.min if b.forked_from_id
      b = b.forked_from
    end
    chain
  end

  def tombstone!
    transaction do
      update!(deleted_at: Time.current, deleted_seq: DbfsV2::Clock.tick!(project_id), materialized: false)
    end
  end

  def to_h
    { id: id, name: name, forked_from: forked_from&.name, fork_seq: fork_seq, seq: seq,
      deleted: deleted?, materialized: materialized }
  end

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end

  def stamp_seq
    return if seq.to_i.positive? || main?
    self.seq = DbfsV2::Clock.tick!(project_id)
  end
end
