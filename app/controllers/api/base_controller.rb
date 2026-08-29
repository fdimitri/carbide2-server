# Base controller for all workspace REST API endpoints — verifies a
# control-minted workspace:api JWT (ADR-023) and resolves the local user
# mirror. The worker has its own path (workspace:rw, verified in worker.rb).
#
# Two distinct identities are exposed, deliberately:
#   current_user  — the LOCAL User mirror (for scoping: current_user.projects)
#   control_user_id — the control-plane user id (for record attribution and
#     matching worker-broadcast user_id). The local id and control id are
#     unrelated; the token only carries the control id.
class Api::BaseController < ActionController::API
  before_action :authenticate!

  attr_reader :control_user_id

  private

  def authenticate!
    token = bearer_token
    unless token
      render json: { error: 'Missing authorization token' }, status: :unauthorized and return
    end

    secret  = ENV.fetch('WORKER_JWT_SECRET')
    payload, = JWT.decode(token, secret, true, { algorithm: 'HS256' })

    # Control-format enforcement (ADR-023). Only workspace:api tokens are
    # accepted on the REST surface; workspace:rw is for the worker only.
    expected_project = ENV['WORKSPACE_PROJECT_ID']&.to_i
    unless payload['iss'] == 'carbide-control' &&
           payload['scope'] == 'workspace:api' &&
           payload['aud'] == "workspace:#{expected_project}" &&
           payload['project_id'].to_i == expected_project
      render json: { error: 'Invalid token scope or audience' }, status: :unauthorized and return
    end

    @control_user_id = payload['user_id']
    @current_user = find_or_create_local_user!(payload['user_email'])
    unless @current_user
      render json: { error: 'Token does not match a known user' }, status: :unauthorized and return
    end
  rescue JWT::DecodeError
    render json: { error: 'Invalid or expired token' }, status: :unauthorized
  end

  # The workspace DB mirrors control users keyed by email. Creation is lazy and
  # idempotent; membership on the single canonical project is granted here, and
  # control already decided the user belongs to this workspace when it minted
  # the token (current_user.control_projects.find in WorkspacesController#token).
  def find_or_create_local_user!(email)
    email = email.to_s.downcase.strip
    return nil if email.empty?

    user = User.find_or_create_by!(email: email) do |u|
      random_password = SecureRandom.base58(32)
      u.password = random_password
      u.password_confirmation = random_password
    end
    ProjectMembership.find_or_create_by!(user: user, project: Project.canonical)
    user
  end

  def current_user
    @current_user
  end

  def bearer_token
    header = request.headers['Authorization']
    header&.start_with?('Bearer ') ? header.split(' ', 2).last : nil
  end
end
