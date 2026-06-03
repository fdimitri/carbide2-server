# API authentication controller for JSON-based login/signup
class Api::AuthController < ActionController::API
  def login
    # The control-plane workspace id this pod represents. Used ONLY to mint a
    # workspace-scoped token from the control plane — it is NOT a local
    # Project primary key (Model B: this pod has exactly one canonical
    # project whose local id is unrelated to the control-plane id).
    workspace_id = control_workspace_id
    unless workspace_id
      render json: { error: 'Workspace id is not configured' }, status: :service_unavailable
      return
    end

    bearer = bearer_token
    unless bearer.present?
      render json: { error: 'Missing control-plane authorization token' }, status: :unauthorized
      return
    end

    exchange = ControlPlaneAuth.new.workspace_token(project_id: workspace_id, control_token: bearer)
    unless exchange.ok
      render json: { error: exchange.error }, status: exchange.status
      return
    end

    control_user = exchange.user
    user = ensure_local_user_and_membership!(control_user)
    token = issue_user_token(user, control_user: control_user)

    render json: {
      user: user_response(user),
      token: token,
      message: 'Login successful'
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def signup
    render json: {
      error: 'Sign up is handled by the control plane. Create your account at /login on the dashboard.'
    }, status: :method_not_allowed
  end

  private

  def auth_params
    params.require(:user).permit(:email, :password, :password_confirmation)
  end

  def bearer_token
    header = request.headers['Authorization']
    header&.start_with?('Bearer ') ? header.split(' ', 2).last : nil
  end

  def user_response(user)
    pref = user.user_preference
    {
      id:                    user.id,
      email:                 user.email,
      first_name:            pref&.first_name,
      last_name:             pref&.last_name,
      username:              pref&.username,
      timezone:              pref&.timezone,
      theme:                 pref&.theme,
      date_format:           pref&.date_format,
      editor_font_size:      pref&.editor_font_size,
      tab_width:             pref&.tab_width,
      notifications_enabled: pref&.notifications_enabled
    }
  end

  def issue_user_token(user, control_user: nil)
    secret = ENV.fetch('WORKER_JWT_SECRET')
    exp = Time.now.to_i + Integer(ENV.fetch('WORKER_TOKEN_EXPIRY_SECONDS', '3600'))
    
    payload = {
      sub: user.id,
      iat: Time.now.to_i,
      exp: exp,
      scopes: ['user:auth']
    }

    if control_user.is_a?(Hash)
      payload[:control_user_id] = control_user['id']
      payload[:control_user_email] = control_user['email']
    end
    
    JWT.encode(payload, secret, 'HS256')
  end

  def control_workspace_id
    raw = ENV['WORKSPACE_PROJECT_ID']
    return nil if raw.blank?
    Integer(raw)
  rescue ArgumentError
    nil
  end

  def ensure_local_user_and_membership!(control_user)
    email = control_user['email'].to_s.downcase.strip
    raise ArgumentError, 'Control user email missing' if email.empty?

    user = User.find_or_initialize_by(email: email)
    if user.new_record?
      random_password = SecureRandom.base58(32)
      user.password = random_password
      user.password_confirmation = random_password
      user.save!
    end

    # Model B: this pod hosts exactly one project; every authenticated user
    # is a member of it. The local project id is unrelated to the
    # control-plane workspace id.
    project = Project.canonical
    ProjectMembership.find_or_create_by!(user: user, project: project)
    user
  end
end
