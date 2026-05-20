# Make flush_interval_s and flush_bytes nullable so nil means "use system default",
# then ensure every existing project has a project_settings row.
class SeedProjectSettingsAndAllowNulls < ActiveRecord::Migration[8.1]
  def up
    # Remove DB-level defaults + NOT NULL so nil is a valid "use system default" value
    change_column_null    :project_settings, :flush_interval_s, true
    change_column_default :project_settings, :flush_interval_s, nil

    change_column_null    :project_settings, :flush_bytes, true
    change_column_default :project_settings, :flush_bytes, nil

    # Seed one row per project that doesn't already have one
    Project.find_each do |project|
      next if ProjectSetting.exists?(project_id: project.id)
      ProjectSetting.create!(project_id: project.id)
    end
  end

  def down
    change_column_null    :project_settings, :flush_interval_s, false, 0.8
    change_column_default :project_settings, :flush_interval_s, 0.8

    change_column_null    :project_settings, :flush_bytes, false, 20
    change_column_default :project_settings, :flush_bytes, 20
  end
end
