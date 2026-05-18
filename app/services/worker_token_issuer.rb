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
      name:    user.email.split('@').first,
      project: project.id,
      iat:     Time.now.to_i,
      exp:     exp
    }
    payload[:terminal] = terminal.id if terminal

    JWT.encode(payload, secret, ALGORITHM)
  end
end
