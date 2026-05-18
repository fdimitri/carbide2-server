class Api::ChatChannelsController < Api::BaseController
  # GET /api/projects/:project_id/chat_channels
  def index
    project = current_user.projects.find(params[:project_id])
    channels = project.chat_channels.order(:name)
    render json: channels.map { |c| channel_json(c) }
  end

  # POST /api/projects/:project_id/chat_channels
  def create
    project = current_user.projects.find(params[:project_id])
    channel = project.chat_channels.create!(name: params.dig(:chat_channel, :name).to_s.strip)
    render json: channel_json(channel), status: :created
  end

  private

  def channel_json(channel)
    {
      id: channel.id,
      project_id: channel.project_id,
      name: channel.name,
      created_at: channel.created_at
    }
  end
end
