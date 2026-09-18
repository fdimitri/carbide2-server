# frozen_string_literal: true
class Revision < ApplicationRecord
  self.primary_key = 'id'

  belongs_to :file_node
  belongs_to :parent, class_name: 'Revision', foreign_key: 'parent_id', optional: true
  belongs_to :second_parent, class_name: 'Revision', foreign_key: 'second_parent_id', optional: true
  belongs_to :branch

  before_validation :assign_id, on: :create
  # ADR-042: every revision takes the project clock's next value inside its own
  # insert transaction, so `seq` order is commit order across the whole
  # project. Done here, not at the four call sites, so none can forget.
  before_create :stamp_seq

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

  def stamp_seq
    self.project_id ||= FileNode.where(id: file_node_id).pick(:project_id)
    return if seq.to_i.positive? # a caller that already ticked (a multi-row operation)
    self.seq = DbfsV2::Clock.tick!(project_id)
  end
end
