# Build/version provenance for this workspace-pod image.
#
# Public (no auth): the client shell fetches this at load — including on the
# login screen, before any token exists — to fill in the SHAs it cannot bake
# itself. The client bakes only its OWN build SHA (it is the client build);
# the server/worker/meta SHAs live in the image env and are reported here.
#
# `/api/v1/common/version` is the service-agnostic contract both the workspace
# server and the control plane implement identically, so the client can call
# one path regardless of which backend answers. `/api/v1/server/version` adds
# server-only runtime detail.
class Api::V1::VersionController < ActionController::API
  def common
    render json: common_payload
  end

  def server
    render json: common_payload.merge(ruby: RUBY_VERSION, rails_env: Rails.env)
  end

  private

  def common_payload
    {
      service: "server",
      version: value("CARBIDE_VERSION"),
      codename: value("CARBIDE_CODENAME"),
      sha: sha("CARBIDE_SERVER_SHA"),
      built_at: value("CARBIDE_BUILD_TIME"),
      components: {
        meta: sha("CARBIDE_META_SHA"),
        server: sha("CARBIDE_SERVER_SHA"),
        worker: sha("CARBIDE_WORKER_SHA"),
      }.compact,
    }
  end

  # Env value, treating the Dockerfile ARG default "unknown" (and blanks) as
  # absent so callers get a clean nil instead of a placeholder string.
  def value(key)
    v = ENV[key].to_s.strip
    v.empty? || v == "unknown" ? nil : v
  end
  alias sha value
end
