# Enforce NOT NULL on projects.user_id; backfill any legacy rows first.
# Requires at least one user to exist; if the users table is empty the migration
# will leave orphaned rows attached to user 1 (acceptable for a dev-only DB).
class EnforceProjectsUserIdNotNull < ActiveRecord::Migration[8.1]
  def up
    # Backfill any rows created before the NOT NULL constraint was added.
    first_user_id = connection.select_value('SELECT MIN(id) FROM users').to_i
    raise "No users exist — cannot backfill projects.user_id" if first_user_id.zero?

    execute <<~SQL
      UPDATE projects SET user_id = #{first_user_id} WHERE user_id IS NULL
    SQL

    change_column_null :projects, :user_id, false
  end

  def down
    change_column_null :projects, :user_id, true
  end
end
