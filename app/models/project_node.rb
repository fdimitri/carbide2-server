# frozen_string_literal: true
# One node in the project DAG. Running nodes are the auto-advancing head
# after a path op: paths → identity, content is the live line. Snapshot nodes
# freeze each file's identity-rev at naming time. The tree itself is a merkle
# directory (`root_tree_id`); this row is kind/parents/name + that root.
class ProjectNode < ApplicationRecord
  self.primary_key = 'id'

  RUNNING  = 'running'
  SNAPSHOT = 'snapshot'

  belongs_to :project_branch
  belongs_to :parent, class_name: 'ProjectNode', optional: true
  belongs_to :second_parent, class_name: 'ProjectNode', optional: true
  belongs_to :root_tree, class_name: 'ProjectTree', optional: true

  # `seq` is the project clock at insert and is not part of the node id.
  # The hash is kind/parents/name/root_tree_id/project_branch_id: trees
  # still share across branches; running nodes do not. Same tree on the
  # same branch still hash-conses; S names when this row was born.

  scope :running,   -> { where(kind: RUNNING) }
  scope :snapshots, -> { where(kind: SNAPSHOT) }

  def running?  = kind == RUNNING
  def snapshot? = kind == SNAPSHOT

  def entries
    DbfsV2::ProjectDag::Index.new(self)
  end

  def entry_rows
    entries.map do |e|
      { file_node_id: e.file_node_id, path: e.path, ftype: e.ftype, revision_id: e.revision_id }
    end
  end
end
