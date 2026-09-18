# frozen_string_literal: true
# A named project state (ADR-042): (seq, branch_set) plus the manifest that
# was materialized from them at naming time. The name is what retains it; the
# manifest is stored so it survives anything later done to the DAG.
class ProjectSnapshot < ApplicationRecord
  self.primary_key = 'id'

  before_validation :assign_id, on: :create

  validates :name, presence: true, uniqueness: { scope: :project_id }

  def branch_set_hash = JSON.parse(branch_set)
  def manifest_hash   = JSON.parse(manifest)

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end
end
