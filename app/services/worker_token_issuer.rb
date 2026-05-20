require 'jwt'

class WorkerTokenIssuer
  ALGORITHM = 'HS256'

  # Issue a project-scoped token. terminal is optional.
  def self.issue!(user:, project:, terminal: nil)
    secret = ENV.fetch('WORKER_JWT_SECRET')
    exp    = Time.now.to_i + Integer(ENV.fetch('WORKER_TOKEN_EXPIRY_SECONDS', '600'))

    payload = {
      sub:     user.id,
      user:    user.id,
      name:    display_name(user),
      project: project.id,
      iat:     Time.now.to_i,
      exp:     exp
    }
    payload[:terminal] = terminal.id if terminal

    JWT.encode(payload, secret, ALGORITHM)
  end

  def self.display_name(user)
    pref = user.user_preference
    return pref.username if pref&.username.present?
    full = [pref&.first_name, pref&.last_name].compact.join(' ').strip
    return full if full.present?
    user.email.split('@').first
  end
  private_class_method :display_name
end
