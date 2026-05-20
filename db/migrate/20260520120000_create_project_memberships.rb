# Replace the single-owner projects.user_id with a many-to-many join table.
# Existing user_id values are migrated into project_memberships before the
# column is dropped, so no data is lost.
class CreateProjectMemberships < ActiveRecord::Migration[8.1]
  def up
    create_table :project_memberships do |t|
      t.references :user,    null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.timestamps
    end
    add_index :project_memberships, [:user_id, :project_id], unique: true

    # Migrate existing ownership rows
    execute <<~SQL
      INSERT INTO project_memberships (user_id, project_id, created_at, updated_at)
      SELECT user_id, id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM projects
      WHERE user_id IS NOT NULL
    SQL

    remove_column :projects, :user_id
  end

  def down
    add_column :projects, :user_id, :integer

    execute <<~SQL
      UPDATE projects
      SET user_id = (
        SELECT user_id FROM project_memberships
        WHERE project_memberships.project_id = projects.id
        LIMIT 1
      )
    SQL

    drop_table :project_memberships
  end
end
