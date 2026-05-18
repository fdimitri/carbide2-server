# Base controller for all API endpoints — handles JWT auth
class Api::BaseController < ActionController::API
  before_action :authenticate!

  private

  def authenticate!
    token = bearer_token
    unless token
      render json: { error: 'Missing authorization token' }, status: :unauthorized and return
    end

    secret  = ENV.fetch('WORKER_JWT_SECRET')
    payload, _ = JWT.decode(token, secret, true, { algorithm: 'HS256' })
    @current_user_id = payload['sub']
  rescue JWT::DecodeError
    render json: { error: 'Invalid or expired token' }, status: :unauthorized
  end

  def current_user
    @current_user ||= User.find(@current_user_id)
  end

  def bearer_token
    header = request.headers['Authorization']
    header&.start_with?('Bearer ') ? header.split(' ', 2).last : nil
  end
end
