# frozen_string_literal: true
class Branch < ApplicationRecord
  self.primary_key = 'id'

  belongs_to :file_node
  belongs_to :head, class_name: 'Revision', foreign_key: 'head_revision_id', optional: true

  before_validation :assign_id, on: :create

  validates :name, presence: true
  validates :name, uniqueness: { scope: :file_node_id }

  MAIN = 'main'

  def self.main_for(file_node_id)
    find_or_create_by!(file_node_id: file_node_id, name: MAIN)
  end

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end
end
