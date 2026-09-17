# AgentTurn — one logical exchange in an AgentConversation: the user's question
# plus the agent's tool loop and final reply, which span several contiguous
# AgentMessage rows. Introduced by ADR-032 (fork anchor) and used by ADR-033
# (side-pane grouping, usage aggregate, TTL scope).
#
# AgentMessage.turn remains the conversation-global linear ordinal; AgentTurn is
# a grouping label via a nullable agent_turn_id. A turn is opened when the
# user's question is persisted and closed when the agent's reply (or error/stop)
# lands, recording the first and last message turn it spans.
class AgentTurn < ApplicationRecord
  STATUSES = %w[in_progress done error stopped].freeze

  belongs_to :agent_conversation
  has_many :agent_messages, -> { order(:turn) }

  validates :status, inclusion: { in: STATUSES }
  validates :start_turn, presence: true,
                         uniqueness: { scope: :agent_conversation_id }

  def done?
    status == 'done'
  end

  def closed?
    status != 'in_progress'
  end

  def close!(status:, end_turn:)
    update!(status: status, end_turn: end_turn)
  end
end
