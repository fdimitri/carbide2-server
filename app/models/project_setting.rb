# ProjectSetting — per-project runtime configuration.
# One row per project (seeded by migration for existing projects).
# Nil values mean "use system default" (enforced in VfsFlusher / ProjectContainer).
class ProjectSetting < ApplicationRecord
  belongs_to :project

  validates :flush_interval_s, numericality: { greater_than: 0.0 }, allow_nil: true
  validates :flush_bytes,      numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :agent_shell_busy_timeout_s,
            numericality: { greater_than: 0, less_than_or_equal_to: 600, only_integer: true },
            allow_nil: true
end
