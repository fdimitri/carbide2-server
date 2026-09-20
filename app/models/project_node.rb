# frozen_string_literal: true
# One node in the project DAG. Running nodes are the auto-advancing head
# after a path op: paths → identity, content is the live line (content_branch).
# Snapshot nodes freeze each file's identity-rev at naming time.
class ProjectNode < ApplicationRecord
  self.primary_key = 'id'

  RUNNING  = 'running'
  SNAPSHOT = 'snapshot'

  belongs_to :project_branch
  belongs_to :parent, class_name: 'ProjectNode', optional: true
  belongs_to :second_parent, class_name: 'ProjectNode', optional: true
  has_many :entries, class_name: 'ProjectNodeEntry', dependent: :delete_all

  scope :running,  -> { where(kind: RUNNING) }
  scope :snapshots, -> { where(kind: SNAPSHOT) }

  def running?  = kind == RUNNING
  def snapshot? = kind == SNAPSHOT

  def entry_rows
    entries.order(:path).map do |e|
      { file_node_id: e.file_node_id, path: e.path, ftype: e.ftype,
        content_branch_id: e.content_branch_id, revision_id: e.revision_id }
    end
  end
end
