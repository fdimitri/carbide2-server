# frozen_string_literal: true
# A content-addressed directory: id is SHA256 of the sorted children.
# Project nodes point at a root tree; unchanged sibling directories are shared.
class ProjectTree < ApplicationRecord
  self.primary_key = 'id'

  has_many :entries, class_name: 'ProjectTreeEntry', foreign_key: :tree_id, dependent: :delete_all
end
