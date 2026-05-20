# Creates per-user preference storage. All columns are nullable — nil means
# "use the application default" at the UI layer. Seeds a row for every
# existing user so the table is never missing a row for an existing account.
class CreateUserPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :user_preferences do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }

      # Identity / display
      t.string  :first_name
      t.string  :last_name
      t.string  :username

      # Locale & presentation
      t.string  :timezone           # IANA zone name, e.g. "America/New_York"
      t.string  :theme              # e.g. "carbide_default"
      t.string  :date_format        # "relative" or "absolute"

      # Editor behaviour
      t.integer :editor_font_size   # nil → system default (13)
      t.integer :tab_width          # nil → 2

      # Notifications
      t.boolean :notifications_enabled  # nil → true

      t.timestamps
    end

    # Seed one row per existing user so the invariant holds immediately
    reversible do |dir|
      dir.up do
        execute <<~SQL
          INSERT INTO user_preferences (user_id, created_at, updated_at)
          SELECT id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM users
        SQL
      end
    end
  end
end
