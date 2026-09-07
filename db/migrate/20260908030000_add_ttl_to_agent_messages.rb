# ADR-033 phase 2: turn-budget TTL. expires_at_turn is the message turn number
# at which this message's lease lapses (null = never expires automatically).
# A turn budget (not wall clock) so a long-lived idle conversation doesn't
# evict its own working context purely by the passage of time. rehydrate_ttl
# resets it; the Resolver decides whether honoring the expiry is worth it.
class AddTtlToAgentMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_messages, :expires_at_turn, :integer
    add_index :agent_messages, [:agent_conversation_id, :expires_at_turn],
              name: 'idx_agent_messages_expiry'
  end
end
