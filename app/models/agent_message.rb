# AgentMessage — one row per OpenAI chat-completion message in an
# AgentConversation's history. The shape mirrors the wire format so
# to_history_entry produces a hash that AgentSession can drop straight
# back into its @history array on resume.
#
# role:
#   'system'    — agent system_prompt snapshot at conversation start
#   'user'      — user input
#   'assistant' — model reply. May have empty content but non-nil
#                 tool_calls_json if the turn was tool-call only.
#   'tool'      — tool result; tool_call_id ties to the assistant's call
class AgentMessage < ApplicationRecord
  belongs_to :agent_conversation

  validates :turn, presence: true,
                   uniqueness: { scope: :agent_conversation_id }
  validates :role, presence: true,
                   inclusion: { in: %w[system user assistant tool] }

  def tool_calls
    return nil if tool_calls_json.blank?
    JSON.parse(tool_calls_json)
  rescue JSON::ParserError
    nil
  end

  # Shape matches what AgentSession#post_chat_completion sends as one
  # element of body[:messages].
  def to_history_entry
    case role
    when 'tool'
      { role: 'tool', tool_call_id: tool_call_id, name: name, content: content.to_s }
    when 'assistant'
      h = { role: 'assistant', content: content }
      tc = tool_calls
      h[:tool_calls] = tc if tc
      h.compact
    else
      { role: role, content: content.to_s }
    end
  end
end
