# Move root_path from projects to project_settings.
# After this migration, project.root_path is gone; use project.project_setting.root_path.
class MoveRootPathToProjectSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :project_settings, :root_path, :string

    # Copy existing root_path values across
    execute <<~SQL
      UPDATE project_settings
      SET root_path = (
        SELECT root_path FROM projects WHERE projects.id = project_settings.project_id
      )
    SQL

    remove_column :projects, :root_path
  end

  def down
    add_column :projects, :root_path, :string

    execute <<~SQL
      UPDATE projects
      SET root_path = (
        SELECT root_path FROM project_settings WHERE project_settings.project_id = projects.id
      )
    SQL

    remove_column :project_settings, :root_path
  end
end
