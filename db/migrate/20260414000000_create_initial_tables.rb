class CreateInitialTables < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.string :email
      t.string :provider
      t.string :uid
      t.timestamps
    end

    create_table :projects do |t|
      t.string :name
      t.string :repo_url
      t.timestamps
    end

    create_table :terminal_sessions do |t|
      t.references :project, foreign_key: true
      t.references :owner, foreign_key: { to_table: :users }
      t.string :pty_cmd
      t.integer :cols, default: 80
      t.integer :rows, default: 24
      t.string :status
      t.timestamps
    end
  end
end
