# AgentTurnUsage — one row per completion request. Despite the name, a "turn"
# here is a single model request (one assistant message + its tool results),
# not the logical AgentTurn grouping: a tool loop issues several requests per
# logical turn. Introduced by ADR-033 phase 2.
class AgentTurnUsage < ApplicationRecord
  belongs_to :agent_conversation
  belongs_to :agent_message, optional: true
end
