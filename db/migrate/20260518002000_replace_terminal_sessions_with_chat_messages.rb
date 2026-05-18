class ReplaceTerminalSessionsWithChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_messages do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.string :name, null: false
      t.text :text, null: false

      t.timestamps
    end

    drop_table :terminal_sessions, if_exists: true
  end
end