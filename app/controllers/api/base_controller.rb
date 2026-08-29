# Base controller for all workspace REST API endpoints — verifies a
# control-minted workspace:api JWT (ADR-023) and resolves the LOCAL user
# mirror (the users table every *.user_id FK in this pod points at). The
# worker has its own path (workspace:rw, verified in worker.rb).
class Api::BaseController < ActionController::API
  before_action :authenticate!

  private

  def authenticate!
    token = bearer_token
    unless token
      render json: { error: 'Missing authorization token' }, status: :unauthorized and return
    end

    # Signature is RS256, verified against the JWKS public keys (ADR-015) —
    # never a shared secret.
    payload = JwtVerifier.verify(token)

    # Control-format enforcement (ADR-023). Only workspace:api tokens are
    # accepted on the REST surface; workspace:rw is for the worker only.
    # Audience guard: the token must name THIS workspace (uuid).
    expected = ENV['WORKSPACE_PROJECT_UUID'].to_s
    unless payload['iss'] == 'carbide-control' &&
           payload['scope'] == 'workspace:api' &&
           (expected.empty? || payload['aud'] == "workspace:#{expected}")
      render json: { error: 'Invalid token scope or issuer' }, status: :unauthorized and return
    end

    @current_project = resolve_project(payload)
    @current_user    = resolve_local_user(payload)
    unless @current_project && @current_user
      render json: { error: 'Token does not match a known user' }, status: :unauthorized and return
    end
  rescue JWT::DecodeError
    render json: { error: 'Invalid or expired token' }, status: :unauthorized
  end

  # Resolve the LOCAL project by its stable control-owned uuid (ADR-015). Under
  # 1:1 this is the workspace uuid, handed to the pod as WORKSPACE_PROJECT_UUID.
  # Fall back to the single canonical project only for local dev without control.
  def resolve_project(payload)
    uuid = payload['project_uuid'].presence
    (uuid && Project.find_by(uuid: uuid)) || Project.canonical
  end

  # The workspace DB mirrors control users keyed by control_uuid, falling back
  # to email. Creation is lazy and idempotent; membership on the resolved
  # project is granted here, and control already decided the user belongs to
  # this workspace when it minted the token.
  def resolve_local_user(payload)
    email = payload['user_email'].to_s.downcase.strip
    return nil if email.empty?
    uuid  = payload['user_uuid'].presence

    user = uuid && User.find_by(control_uuid: uuid)
    return user if user

    user = User.find_by(email: email)
    if user
      user.update_column(:control_uuid, uuid) if uuid && user.control_uuid.nil?
    else
      random_password = SecureRandom.base58(32)
      user = User.create!(
        email: email,
        control_uuid: uuid,
        password: random_password,
        password_confirmation: random_password
      )
    end
    ProjectMembership.find_or_create_by!(user: user, project: @current_project)
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
