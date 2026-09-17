# ADR-032 fork lineage: forked_from_id is a self-FK naming the ancestor; a
# fork is a NEW conversation (deep copy of the ancestor's messages up to a
# fork point), so lineage is one parent per row. forked_at_turn is the message
# turn number at the fork boundary (the end of the chosen AgentTurn).
#
# Additive and nullable — existing conversations are roots (forked_from_id nil).
class AddForkLineageToAgentConversations < ActiveRecord::Migration[8.1]
  def change
    add_reference :agent_conversations, :forked_from,
                  foreign_key: { to_table: :agent_conversations }
    add_column :agent_conversations, :forked_at_turn, :integer
  end
end
