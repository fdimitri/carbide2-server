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
#
# Tombstone (ADR-033): evicted_at is set when a message's payload is evicted
# from the prompt. The row is kept (turn/tool_call_id/name survive); only the
# payload is omitted from to_history_entry.
class AgentMessage < ApplicationRecord
  belongs_to :agent_conversation
  # Optional: only role=user rows carry an author (see #79).
  belongs_to :user, optional: true

  validates :turn, presence: true,
                   uniqueness: { scope: :agent_conversation_id }
  validates :role, presence: true,
                   inclusion: { in: %w[system user assistant tool] }

  scope :evicted,     -> { where.not(evicted_at: nil) }
  scope :not_evicted, -> { where(evicted_at: nil) }

  def evicted?
    evicted_at.present?
  end

  def tombstone!
    update_column(:evicted_at, Time.current)
  end

  def restore!
    update_column(:evicted_at, nil)
  end

  def tool_calls
    return nil if tool_calls_json.blank?
    JSON.parse(tool_calls_json)
  rescue JSON::ParserError
    nil
  end

  # Shape matches what AgentSession#post_chat_completion sends as one
  # element of body[:messages]. An evicted message omits its payload —
  # tool result `content`, or tool call `arguments` — but keeps the
  # structural fields so the tool-call pairing stays valid.
  def to_history_entry
    case role
    when 'tool'
      entry = { role: 'tool', tool_call_id: tool_call_id, name: name }
      entry[:content] = content.to_s unless evicted?
      entry
    when 'assistant'
      h = { role: 'assistant', content: content }
      tc = evicted? ? evicted_tool_calls : tool_calls
      h[:tool_calls] = tc if tc
      h.compact
    else
      { role: role, content: content.to_s }
    end
  end

  private

  # tool_calls with arguments stripped — keeps id + function.name so the
  # matching tool result row still pairs, but drops the (large) call text.
  def evicted_tool_calls
    tool_calls&.map do |tc|
      fn = tc['function'] || {}
      { 'id' => tc['id'],
        'type' => tc['type'] || 'function',
        'function' => { 'name' => fn['name'] } }
    end
  end
end
