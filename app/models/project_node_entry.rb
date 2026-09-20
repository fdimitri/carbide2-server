# frozen_string_literal: true
# One path on one project-DAG node: location → identity, plus the content
# binding (live content_branch on a running node; frozen revision_id on a snapshot).
class ProjectNodeEntry < ApplicationRecord
  belongs_to :project_node
  belongs_to :file_node
  belongs_to :content_branch, class_name: 'Branch', optional: true

  def folder?  = ftype == 'folder'
  def root?    = path == '/'
  def deleted? = false
  def project_branch = project_node&.project_branch
end
