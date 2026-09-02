class AddAgentShellPeekTailBytes < ActiveRecord::Migration[8.1]
  def up
    # ProjectSetting: default number of scrollback bytes the agent's
    # shell_peek_buffer tool returns when the model does not pass an explicit
    # tail_bytes. Seeded to a sane 1KB for every existing project; the row is
    # the only source of the default (no code constant, no env fallback).
    add_column :project_settings, :agent_shell_peek_tail_bytes, :integer,
               default: 1024, null: false
  end

  def down
    remove_column :project_settings, :agent_shell_peek_tail_bytes
  end
end
