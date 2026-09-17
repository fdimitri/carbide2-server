# ADR-033 phase 1: tombstone flag on agent_messages. An evicted message keeps
# its structural fields (turn, tool_call_id, name) but omits its payload —
# tool result `content` or tool call `arguments` — when serialized back into
# the wire history (AgentMessage#to_history_entry). The row is never deleted;
# clearing the flag restores it.
class AddEvictedAtToAgentMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_messages, :evicted_at, :datetime
    add_index :agent_messages, [:agent_conversation_id, :evicted_at],
              name: 'idx_agent_messages_evicted'
  end
end
