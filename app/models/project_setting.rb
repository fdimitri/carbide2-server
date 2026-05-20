# ProjectSetting — per-project runtime configuration.
# One row per project (created on first PATCH /api/projects/:id/settings).
# When a row does not exist the column defaults apply (see migration).
class ProjectSetting < ApplicationRecord
  belongs_to :project

  validates :flush_interval_s, numericality: { greater_than: 0.0 }, allow_nil: true
  validates :flush_bytes,      numericality: { greater_than: 0, only_integer: true }, allow_nil: true
end
