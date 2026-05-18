class Api::ChatMessagesController < Api::BaseController
  # GET /api/projects/:project_id/chat_channels/:chat_channel_id/chat_messages
  def index
    project = current_user.projects.find(params[:project_id])
    channel = project.chat_channels.find(params[:chat_channel_id])
    messages = channel.chat_messages.order(created_at: :asc).last(200)

    render json: messages.map { |m| message_json(m) }
  end

  # POST /api/projects/:project_id/chat_channels/:chat_channel_id/chat_messages
  def create
    project = current_user.projects.find(params[:project_id])
    channel = project.chat_channels.find(params[:chat_channel_id])
    text = params.dig(:chat_message, :text).to_s.strip

    message = channel.chat_messages.create!(
      user: current_user,
      name: current_user.email.split('@').first,
      text: text
    )

    render json: message_json(message), status: :created
  end

  private

  def message_json(message)
    {
      id: message.id,
      project_id: message.chat_channel.project_id,
      chat_channel_id: message.chat_channel_id,
      user_id: message.user_id,
      name: message.name,
      text: message.text,
      timestamp: message.created_at
    }
  end
end