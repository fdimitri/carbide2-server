class AddChatChannelsAndRekeyMessages < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_channels do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    add_index :chat_channels, [:project_id, :name], unique: true

    add_reference :chat_messages, :chat_channel, null: true, foreign_key: true

    say_with_time 'Backfilling chat_channels for existing chat_messages' do
      project_ids = select_values('SELECT DISTINCT project_id FROM chat_messages WHERE project_id IS NOT NULL')
      project_ids.each do |pid|
        channel_id = select_value(<<~SQL)
          INSERT INTO chat_channels (project_id, name, created_at, updated_at)
          VALUES (#{pid.to_i}, 'general', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          ON CONFLICT(project_id, name) DO UPDATE SET updated_at = CURRENT_TIMESTAMP
          RETURNING id
        SQL

        execute <<~SQL
          UPDATE chat_messages
          SET chat_channel_id = #{channel_id.to_i}
          WHERE project_id = #{pid.to_i} AND chat_channel_id IS NULL
        SQL
      end
    end

    change_column_null :chat_messages, :chat_channel_id, false
    remove_reference :chat_messages, :project, foreign_key: true
  end

  def down
    add_reference :chat_messages, :project, null: true, foreign_key: true

    execute <<~SQL
      UPDATE chat_messages
      SET project_id = chat_channels.project_id
      FROM chat_channels
      WHERE chat_messages.chat_channel_id = chat_channels.id
    SQL

    change_column_null :chat_messages, :project_id, false
    remove_reference :chat_messages, :chat_channel, foreign_key: true

    drop_table :chat_channels
  end
end
