# One node as a non-main project branch currently has it: its path on that
# branch and where its content comes from — `content_branch` once the branch
# has written the file, else pinned at `revision_id` (the parent's head at the
# fork). Tombstoned entries (`deleted_at`) keep the node known to the branch
# so a re-create at the path resurrects the same identity, as file_nodes does
# for main.
class BranchEntry < ApplicationRecord
  belongs_to :project_branch
  belongs_to :file_node
  belongs_to :content_branch, class_name: 'Branch', optional: true

  scope :live,       -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }

  def deleted? = deleted_at.present?
  def folder?  = ftype == 'folder'
  def root?    = path == '/'
end
