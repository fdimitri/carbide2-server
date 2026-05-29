class AddAgentExtensions < ActiveRecord::Migration[8.1]
  def change
    # ──────────────────────────────────────────────────────────────────────
    # Agent: gate the shell_exec tool independently of the allowed_tools
    # JSON list. Belt-and-braces: AgentTools.invoke also re-checks this so
    # an admin who forgets to update allowed_tools still can't accidentally
    # enable shell_exec.
    # ──────────────────────────────────────────────────────────────────────
    add_column :agents, :shell_exec_enabled, :boolean, default: false, null: false

    # ──────────────────────────────────────────────────────────────────────
    # ProjectSetting: hard upper bound (seconds) on how long a terminal may
    # be in the agent_busy lock state before the worker auto-releases user
    # input. Prevents a wedged agent from locking out the user forever.
    # ──────────────────────────────────────────────────────────────────────
    add_column :project_settings, :agent_shell_busy_timeout_s, :integer,
               default: 60, null: false

    # ──────────────────────────────────────────────────────────────────────
    # AgentConversation: persisted chat thread between a user and an agent
    # in one project. The worker's in-memory AgentSession is keyed by the
    # conversation_id (UUID) so a reconnecting client can resume; this
    # table makes that survive a worker restart too.
    # ──────────────────────────────────────────────────────────────────────
    create_table :agent_conversations do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user,    null: false, foreign_key: true
      t.references :agent,   null: false, foreign_key: true
      t.string  :uuid,    null: false   # client-facing conversation id
      t.string  :title                  # auto-generated from first message
      t.datetime :last_activity_at
      t.timestamps
    end
    add_index :agent_conversations, :uuid, unique: true
    add_index :agent_conversations, [:project_id, :user_id, :last_activity_at],
              name: 'idx_agent_convos_recent'

    # ──────────────────────────────────────────────────────────────────────
    # AgentMessage: one row per OpenAI chat-completion message in the
    # history. role ∈ {system, user, assistant, tool}. For role=assistant
    # with tool_calls, the calls are stored as JSON in tool_calls_json.
    # For role=tool, tool_call_id ties the result back to the call.
    # ──────────────────────────────────────────────────────────────────────
    create_table :agent_messages do |t|
      t.references :agent_conversation, null: false, foreign_key: true
      t.integer :turn,         null: false   # monotonic per-conversation
      t.string  :role,         null: false
      t.text    :content                     # nil for tool-only assistant turns
      t.string  :tool_call_id                # role=tool only
      t.string  :name                        # role=tool only — tool slug
      t.text    :tool_calls_json             # role=assistant, JSON-encoded array
      t.timestamps
    end
    add_index :agent_messages, [:agent_conversation_id, :turn], unique: true
  end
end
