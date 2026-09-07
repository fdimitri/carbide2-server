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
  has_many :agent_turns, -> { order(:start_turn) }, dependent: :destroy

  # ADR-032 fork lineage: a fork names its ancestor; the ancestor may have many
  # forks. Recursive ancestry is walked via forked_from_id (parent until nil).
  belongs_to :forked_from, class_name: 'AgentConversation', optional: true
  has_many :forks, class_name: 'AgentConversation', foreign_key: :forked_from_id,
                   dependent: :nullify

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
  def append!(turn:, role:, content: nil, tool_calls: nil, tool_call_id: nil, name: nil,
              user_id: nil)
    agent_messages.create!(
      turn:            turn,
      role:            role,
      content:         content,
      tool_call_id:    tool_call_id,
      name:            name,
      user_id:         user_id,
      tool_calls_json: tool_calls && tool_calls.to_json,
    )
    update_column(:last_activity_at, Time.current)
  end

  # Reconstruct the @history list for AgentSession from the persisted rows.
  def to_history
    agent_messages.map(&:to_history_entry)
  end

  # ADR-032: fork this conversation at a turn boundary into a new, independent
  # conversation. Deep-copies messages with turn <= fork_at_turn (renumbered
  # 0..N), inherits title + visibility, and records lineage. The forker is the
  # new owner. Returns the new AgentConversation.
  def fork_from!(forker:, fork_at_turn:)
    prefix = agent_messages.where('turn <= ?', fork_at_turn).order(:turn).to_a
    raise ArgumentError, 'fork point has no messages' if prefix.empty?

    fork = self.class.create!(
      project:       project,
      user:          forker,
      agent:         agent,
      uuid:          SecureRandom.uuid,
      title:         title,
      visibility:    visibility,
      forked_from:   self,
      forked_at_turn: fork_at_turn,
      last_activity_at: Time.current,
    )

    prefix.each do |m|
      fork.agent_messages.create!(
        turn:            m.turn,
        role:            m.role,
        content:         m.content,
        tool_call_id:    m.tool_call_id,
        name:            m.name,
        tool_calls_json: m.tool_calls_json,
        user_id:         m.user_id,
        evicted_at:      m.evicted_at,
      )
    end
    fork
  end

  # Ancestors of this conversation, from immediate parent back to the root
  # (a conversation whose forked_from_id is nil).
  def ancestry
    out  = []
    cur  = forked_from
    while cur
      out << cur
      cur = cur.forked_from
    end
    out
  end
end
