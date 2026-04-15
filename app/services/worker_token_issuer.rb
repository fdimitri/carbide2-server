require 'jwt'

class WorkerTokenIssuer
  ALGORITHM = 'HS256'

  def self.issue!(user:, project:, terminal:)
    secret = ENV.fetch('WORKER_JWT_SECRET')
    exp = Time.now.to_i + Integer(ENV.fetch('WORKER_TOKEN_EXPIRY_SECONDS', '600'))

    payload = {
      sub: user.id,
      project: project.id,
      terminal: terminal.id,
      iat: Time.now.to_i,
      exp: exp,
      scopes: ['terminal:connect']
    }

    JWT.encode(payload, secret, ALGORITHM)
  end
end
