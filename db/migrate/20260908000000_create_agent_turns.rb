# ADR-032 schema: AgentTurn groups the contiguous AgentMessage rows of one
# logical exchange (user question + the agent's tool loop + final reply).
#
# AgentMessage.turn stays a conversation-global linear ordinal; AgentTurn is a
# nullable, additive grouping key (agent_turn_id on agent_messages) that names
# "these consecutive messages are one thing" — the unit fork points at and the
# side-pane / usage aggregate over. Nothing re-parents: to_history still reads
# order(:turn).
class CreateAgentTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_turns do |t|
      t.references :agent_conversation, null: false, foreign_key: true
      # State of this exchange. A turn is created when the user's question is
      # persisted and closed when the agent's reply (or error/stop) lands.
      t.string  :status, null: false, default: 'in_progress'
      t.integer :start_turn, null: false   # first AgentMessage.turn in this turn
      t.integer :end_turn                 # last AgentMessage.turn (set on close)
      t.timestamps
    end
    add_index :agent_turns, [:agent_conversation_id, :start_turn], unique: true

    add_reference :agent_messages, :agent_turn, foreign_key: true
  end
end
