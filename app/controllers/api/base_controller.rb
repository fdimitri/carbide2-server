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

    # A structurally-valid token can still reference a user that does not
    # exist in THIS pod's database (e.g. a token minted by another workspace
    # pod and replayed here — same browser origin, different DB/user ids).
    # That is an authentication failure (401), not a missing resource (404):
    # otherwise current_user's `User.find` raises RecordNotFound and every
    # endpoint returns a misleading 404.
    @current_user = User.find_by(id: @current_user_id)
    unless @current_user
      render json: { error: 'Token does not match a known user' }, status: :unauthorized and return
    end
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
