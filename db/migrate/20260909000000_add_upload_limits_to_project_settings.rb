# Per-project upload limits for ArchiveImporter. Nil means "no limit" — the
# importer treats a missing setting as unlimited, so a project with no row (or
# a row with nulls) accepts files/archives of any size. Replaces the old
# hardcoded MAX_ENTRY_BYTES / MAX_TOTAL_BYTES / MAX_ENTRIES constants.
class AddUploadLimitsToProjectSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :project_settings, :upload_max_entry_bytes, :integer
    add_column :project_settings, :upload_max_total_bytes, :integer
    add_column :project_settings, :upload_max_entries,     :integer
  end
end
