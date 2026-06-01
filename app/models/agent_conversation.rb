# AgentConversation — one persistent chat thread between a user and an
# Agent within a project. The worker's in-memory AgentSession is keyed by
# the uuid; this table makes conversations survive a worker restart so
# anyone in the project can pick a thread back up after a deploy.
#
# visibility:
#   'project' — anyone in the project may load + watch live (default)
#   'private' — only the originating user_id may load/watch
# title is auto-generated (truncated first user message); rename UI TBD.
class AgentConversation < ApplicationRecord
  VISIBILITIES = %w[project private].freeze

  belongs_to :project
  belongs_to :user      # who started it (attribution)
  belongs_to :agent
  has_many :agent_messages, -> { order(:turn) }, dependent: :destroy

  validates :uuid, presence: true, uniqueness: true
  validates :visibility, inclusion: { in: VISIBILITIES }

  # Conversations a given viewer is allowed to see within a project:
  # all shared (project-visible) ones + the viewer's own private ones.
  scope :visible_to, ->(viewer_user_id, project_id) {
    where(project_id: project_id).where(
      'visibility = ? OR (visibility = ? AND user_id = ?)',
      'project', 'private', viewer_user_id,
    ).order(last_activity_at: :desc)
  }

  # Back-compat for callers that filtered to just the owner's threads.
  scope :recent_for_user_in_project, ->(user_id, project_id) {
    where(user_id: user_id, project_id: project_id).order(last_activity_at: :desc)
  }

  def visible_to?(viewer_user_id)
    visibility == 'project' || user_id == viewer_user_id
  end

  def project_visible?
    visibility == 'project'
  end

  # Append a message row. Caller passes a hash matching the worker's
  # @history entries: role + content + tool_calls + tool_call_id + name.
  def append!(turn:, role:, content: nil, tool_calls: nil, tool_call_id: nil, name: nil)
    agent_messages.create!(
      turn:            turn,
      role:            role,
      content:         content,
      tool_call_id:    tool_call_id,
      name:            name,
      tool_calls_json: tool_calls && tool_calls.to_json,
    )
    update_column(:last_activity_at, Time.current)
  end

  # Reconstruct the @history list for AgentSession from the persisted rows.
  def to_history
    agent_messages.map(&:to_history_entry)
  end
end
