# Export an agent conversation as lossless JSON for debugging / inspection.
#
# Under the new /api/v1/<backend>/<resource> shape (ADR-025 §1b): the
# backend cardinality segment is `server`, matching control's `control`.
# Only this endpoint lives here for now; the legacy flat /api resources
# migrate onto this prefix separately.
class Api::V1::Server::AgentConversationsController < Api::BaseController
  # GET /api/v1/server/projects/:project_id/agent_conversations/:uuid/export
  def export
    convo = AgentConversation.find_by(uuid: params[:uuid], project_id: params[:project_id])
    return render json: { error: 'conversation not found' }, status: :not_found unless convo

    # Must be a member of the project (not just able to see the conversation's
    # visibility) — centralized project gate.
    authorize_project_membership!(convo.project)
    return if performed?

    return render json: { error: 'conversation is private' }, status: :forbidden unless convo.visible_to?(current_user.id)

    render json: export_json(convo)
  end

  private

  def export_json(convo)
    agent = convo.agent
    {
      metadata: {
        generator: 'carbide2-server agent_conversation export',
        generator_note: 'system_prompt is snapshotted in the turn-0 system message; ' \
                        'all other agent config (model, provider_url, sampling, tools) ' \
                        'is the agent\u0027s current live value, not a per-message snapshot.',
        exported_at: Time.current.utc.iso8601,
      },
      conversation: {
        uuid:             convo.uuid,
        title:            convo.title,
        visibility:       convo.visibility,
        owner_user_id:    convo.user_id,
        project_id:       convo.project_id,
        created_at:       convo.created_at.iso8601,
        last_activity_at: convo.last_activity_at&.iso8601,
        agent: {
          slug:            agent.slug,
          name:            agent.name,
          role:            agent.role,
          model:           agent.model,
          provider_url:    agent.provider_url,
          sampling:        agent.sampling_params,
          allowed_tools:   agent.allowed_tool_slugs,
          shell_exec_enabled: agent.shell_exec_enabled,
          max_turns:       agent.max_turns,
          system_prompt:   agent.system_prompt,
        },
      },
      messages: convo.agent_messages.map { |m| message_json(m) },
    }
  end

  def message_json(m)
    {
      turn:          m.turn,
      role:          m.role,
      content:       m.content,
      tool_call_id:  m.tool_call_id,
      tool_name:     m.name,
      tool_calls:    m.tool_calls,
      user_id:       m.user_id,
      created_at:    m.created_at.iso8601,
    }
  end
end
