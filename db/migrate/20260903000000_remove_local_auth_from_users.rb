# Drop the Devise + omniauth credential columns from the workspace-local user
# mirror. The pod never authenticates locally (control mints the tokens —
# ADR-015/023); the users table only mirrors identity keyed by control_uuid.
class RemoveLocalAuthFromUsers < ActiveRecord::Migration[8.1]
  def up
    remove_index :users, :reset_password_token if index_exists?(:users, :reset_password_token)
    remove_column :users, :encrypted_password
    remove_column :users, :reset_password_token
    remove_column :users, :reset_password_sent_at
    remove_column :users, :remember_created_at
    remove_column :users, :sign_in_count
    remove_column :users, :current_sign_in_at
    remove_column :users, :last_sign_in_at
    remove_column :users, :current_sign_in_ip
    remove_column :users, :last_sign_in_ip
    remove_column :users, :provider
    remove_column :users, :uid
  end

  def down
    add_column :users, :encrypted_password, :string, null: false, default: ""
    add_column :users, :reset_password_token, :string
    add_column :users, :reset_password_sent_at, :datetime
    add_column :users, :remember_created_at, :datetime
    add_column :users, :sign_in_count, :integer, default: 0, null: false
    add_column :users, :current_sign_in_at, :datetime
    add_column :users, :last_sign_in_at, :datetime
    add_column :users, :current_sign_in_ip, :string
    add_column :users, :last_sign_in_ip, :string
    add_column :users, :provider, :string
    add_column :users, :uid, :string
    add_index :users, :reset_password_token, unique: true
  end
end
