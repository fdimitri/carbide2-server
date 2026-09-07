# ADR-033 phase 2: per-completion-request usage. Because we stream (SSE), the
# model returns `usage` once per completion REQUEST — on the final chunk — not
# per agent_messages row. One request = one assistant message (whose
# tool_calls_json holds the call spec) plus any tool result rows that follow.
#
# So usage keys to the assistant message (agent_message_id), not to the
# per-message `turn` and not 1:1 to AgentTurn (a tool loop makes several
# requests per logical turn).
#
# Cost is NOT returned by the API — derived later from a model→price table.
class CreateAgentTurnUsage < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_turn_usages do |t|
      t.references :agent_conversation, null: false, foreign_key: true
      t.references :agent_message,      null: true,  foreign_key: true
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :total_tokens
      t.integer :cached_tokens   # usage.prompt_tokens_details.cached_tokens; nullable
      t.timestamps
    end
    add_index :agent_turn_usages, [:agent_conversation_id, :created_at],
              name: 'idx_agent_turn_usage_recent'
  end
end
