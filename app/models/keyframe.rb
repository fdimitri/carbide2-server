# frozen_string_literal: true
class Keyframe < ApplicationRecord
  self.primary_key = 'id'

  belongs_to :file_node
  belongs_to :revision

  before_validation :assign_id, on: :create

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end
end
