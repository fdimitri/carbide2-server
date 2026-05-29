# Enforce NOT NULL on projects.user_id; backfill any legacy rows first.
# If there are no projects yet, just flip the constraint — there is nothing
# to backfill. If projects exist but no users do, fail loudly: the dev DB
# is inconsistent.
class EnforceProjectsUserIdNotNull < ActiveRecord::Migration[8.1]
  def up
    pending = connection.select_value('SELECT COUNT(*) FROM projects WHERE user_id IS NULL').to_i

    if pending > 0
      first_user_id = connection.select_value('SELECT MIN(id) FROM users').to_i
      raise "No users exist — cannot backfill projects.user_id" if first_user_id.zero?

      execute <<~SQL
        UPDATE projects SET user_id = #{first_user_id} WHERE user_id IS NULL
      SQL
    end

    change_column_null :projects, :user_id, false
  end

  def down
    change_column_null :projects, :user_id, true
  end
end
