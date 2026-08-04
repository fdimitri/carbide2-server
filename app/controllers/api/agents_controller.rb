# Agents API — list and edit the workspace's LLM personas at runtime.
#
# Agents are workspace-global (one Agents table per workspace DB), so this
# is a top-level /api/agents resource, not nested under a project. The
# worker's AgentSession reads these rows by slug; editing here lets an admin
# repoint provider_url/model, toggle tools, or enable/disable an agent
# without redeploying or re-seeding.
#
# api_key is never returned (only a boolean `api_key_set`); it is only
# written when a non-blank value is supplied, so re-saving a form that left
# the key field empty does not wipe an existing secret.
class Api::AgentsController < Api::BaseController
  def index
    render json: Agent.order(:role, :slug).map { |a| agent_json(a) }
  end

  def show
    render json: agent_json(find_agent)
  end

  def update
    agent = find_agent
    agent.assign_attributes(agent_params)
    agent.allowed_tools = normalized_tools    if params.key?(:allowed_tools)
    agent.sampling      = normalized_sampling if params.key?(:sampling)
    # Only overwrite the stored key when a non-blank value is supplied.
    agent.api_key = params[:api_key] if params[:api_key].present?
    agent.save!
    render json: agent_json(agent)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') },
           status: :unprocessable_entity
  end

  private

  def find_agent
    Agent.find(params[:id])
  end

  # api_key is handled separately (see #update); slug is immutable here.
  def agent_params
    params.permit(:name, :description, :provider_url, :model,
                  :system_prompt, :role, :enabled, :shell_exec_enabled)
  end

  def normalized_tools
    Array(params[:allowed_tools]).map(&:to_s).reject(&:blank?)
  end

  def normalized_sampling
    raw = params[:sampling]
    return {} if raw.blank?
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
  end

  def agent_json(a)
    {
      id:                 a.id,
      slug:               a.slug,
      name:               a.name,
      description:        a.description,
      provider_url:       a.provider_url,
      model:              a.model,
      api_key_set:        a.api_key.present?,
      system_prompt:      a.system_prompt,
      allowed_tools:      a.allowed_tool_slugs,
      sampling:           a.sampling_params,
      role:               a.role,
      enabled:            a.enabled,
      shell_exec_enabled: a.shell_exec_enabled,
    }
  end
end
