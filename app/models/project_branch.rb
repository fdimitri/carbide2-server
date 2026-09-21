# A branch of the whole project: a ref at a running project-DAG node
# (`head_node`). FileEvents are notifications, not the source of the tree.
# Identity is the uuid: a tombstoned name can be reused by a new row without
# reviving this one's history.
#
# `main` is a row like any other. FileNode is identity (uuid, posix, content
# DAG), not the live path. The live path is an entry on `head_node`.
class ProjectBranch < ApplicationRecord
  self.primary_key = 'id'

  MAIN = Branch::MAIN

  belongs_to :base_branch, class_name: 'ProjectBranch', optional: true
  belongs_to :forked_from, class_name: 'ProjectBranch', optional: true
  belongs_to :head_node, class_name: 'ProjectNode', optional: true
  belongs_to :fork_node, class_name: 'ProjectNode', optional: true
  belongs_to :base_node, class_name: 'ProjectNode', optional: true
  has_many :project_nodes, dependent: :delete_all
  has_many :file_events
  has_many :content_branches, class_name: 'Branch'

  # Live path index: the merkle tree at `head_node`, not a table of rows.
  # `head_entries` is a flat-path facade over that tree (ProjectDag::Index).
  def head_entries
    head_node ? head_node.entries : DbfsV2::ProjectDag::Index.empty
  end

  before_validation :assign_id, on: :create
  before_create :stamp_seq

  validates :name, presence: true

  scope :live,       -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }

  def self.main_for(project_id)
    live.find_by(project_id: project_id, name: MAIN) ||
      live.find_or_create_by!(project_id: project_id, name: MAIN) { |b| b.seq = 0 }
  rescue ActiveRecord::RecordNotUnique
    # Two first-writers on a new project both tried to insert `main`.
    live.find_by!(project_id: project_id, name: MAIN)
  end

  def main?    = name == MAIN && forked_from_id.nil?
  def deleted? = deleted_at.present?

  def tombstone!
    transaction do
      update!(deleted_at: Time.current, deleted_seq: DbfsV2::Clock.tick!(project_id), materialized: false)
    end
  end

  def to_h
    { id: id, name: name, forked_from: forked_from&.name, fork_seq: fork_seq, base_seq: base_seq, seq: seq,
      base_branch: base_branch&.name, deleted: deleted?, materialized: materialized }
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
