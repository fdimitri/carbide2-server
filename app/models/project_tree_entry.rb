# frozen_string_literal: true
# One child of a merkle directory: a basename → identity, plus either a
# child tree (folder) or a frozen revision (snapshot file). Running content
# is not stored here; it is the live line (file_node, project_branch).
class ProjectTreeEntry < ApplicationRecord
  belongs_to :tree, class_name: 'ProjectTree', foreign_key: :tree_id
  belongs_to :file_node
  belongs_to :child_tree, class_name: 'ProjectTree', optional: true
  belongs_to :revision, optional: true

  def folder? = ftype == 'folder'
end
