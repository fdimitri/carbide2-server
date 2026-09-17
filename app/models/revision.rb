# frozen_string_literal: true
class Revision < ApplicationRecord
  self.primary_key = 'id'

  belongs_to :file_node
  belongs_to :parent, class_name: 'Revision', foreign_key: 'parent_id', optional: true
  belongs_to :second_parent, class_name: 'Revision', foreign_key: 'second_parent_id', optional: true
  belongs_to :branch

  before_validation :assign_id, on: :create

  # The single source of truth for change types and their payload shape.
  CHANGE_TYPES = %w[
    setContents
    insertDataSingleLine
    deleteDataSingleLine
    insertDataMultiLine
    deleteDataMultiLine
    replaceDataSingleLine
    replaceDataMultiLine
    pcreReplaceSingleLine
    pcreReplaceMultiLine
    writeBinary
  ].freeze

  validates :change_type, inclusion: { in: CHANGE_TYPES }

  def merge_commit?
    second_parent_id.present?
  end

  def genesis?
    parent_id.nil?
  end

  def payload
    @payload ||= change_data.blank? ? {} : JSON.parse(change_data)
  end

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end
end
