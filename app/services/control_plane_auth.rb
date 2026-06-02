require 'json'
require 'net/http'
require 'uri'

# ControlPlaneAuth delegates credential checks and project-membership
# authorization to carbide2-control. Workspace pods then mirror the user
# locally only after control has authenticated + authorized access.
class ControlPlaneAuth
  DEFAULT_BASE = 'http://control-plane.carbide-system.svc.cluster.local:3001'.freeze

  Result = Struct.new(:ok, :status, :error, :user, :token, keyword_init: true)

  def initialize(base_url: ENV['CONTROL_API_BASE'])
    @base_url = (base_url.presence || DEFAULT_BASE).to_s.sub(%r{/+\z}, '')
  end

  # Authenticate credentials against control-plane and verify the user is a
  # member of +project_id+ there.
  def login(email:, password:, project_id:)
    login_resp = post_json('/api/login', { user: { email: email, password: password } })
    unless login_resp[:ok]
      return Result.new(ok: false, status: :unauthorized, error: 'Invalid email or password')
    end

    token = login_resp[:json]['token']
    user  = login_resp[:json]['user']
    unless token.present? && user.is_a?(Hash)
      return Result.new(ok: false, status: :bad_gateway, error: 'Control auth returned malformed response')
    end

    member_resp = get_json("/api/projects/#{project_id}", bearer: token)
    unless member_resp[:ok]
      return Result.new(ok: false, status: :forbidden, error: 'You are not a member of this workspace project')
    end

    Result.new(ok: true, status: :ok, user: user)
  rescue StandardError => e
    Rails.logger.error("[control-auth] login failed: #{e.class}: #{e.message}")
    Result.new(ok: false, status: :service_unavailable, error: 'Control auth service unavailable')
  end

  def workspace_token(project_id:, control_token:)
    resp = get_json("/api/projects/#{project_id}/ws_token", bearer: control_token)
    unless resp[:ok]
      return Result.new(ok: false, status: resp[:code] == 401 ? :unauthorized : :forbidden, error: 'Control-plane rejected workspace access')
    end

    json = resp[:json]
    user = json['user']
    token = json['token']
    if token.blank? || !user.is_a?(Hash)
      return Result.new(ok: false, status: :bad_gateway, error: 'Control-plane returned malformed workspace token response')
    end

    Result.new(ok: true, status: :ok, user: user, token: token)
  rescue StandardError => e
    Rails.logger.error("[control-auth] workspace token exchange failed: #{e.class}: #{e.message}")
    Result.new(ok: false, status: :service_unavailable, error: 'Control auth service unavailable')
  end

  private

  def post_json(path, body, bearer: nil)
    request_json(Net::HTTP::Post, path, body: body, bearer: bearer)
  end

  def get_json(path, bearer: nil)
    request_json(Net::HTTP::Get, path, bearer: bearer)
  end

  def request_json(http_klass, path, body: nil, bearer: nil)
    uri = URI.parse("#{@base_url}#{path}")
    req = http_klass.new(uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{bearer}" if bearer.present?
    req.body = JSON.generate(body) if body

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 5, open_timeout: 2) do |http|
      resp = http.request(req)
      json = resp.body.present? ? JSON.parse(resp.body) : {}
      { ok: resp.code.to_i.between?(200, 299), code: resp.code.to_i, json: json }
    end
  end
end
