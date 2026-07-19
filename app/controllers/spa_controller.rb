# Serves the SPA shell for any non-API, non-asset path so the Vue router's
# history-mode URLs (e.g. /login, /preferences) survive a hard reload. The
# static assets under /assets/* and /clients/* are served by
# ActionDispatch::Static before the router; this controller only runs for SPA
# route fallbacks.
#
# The Decider: when a content-addressed client store is present (see
# ClientRegistry) this resolves a *pinned* build and serves that build's
# index.html. The choice comes from a `?client=` query param (which also pins a
# cookie for subsequent navigations) or the `carbide_client` cookie, defaulting
# to the newest build of the default family. The build's assets are already
# absolute (/clients/<family>/<sha>/...), so we only inject <base href> for the
# workspace prefix, which the client uses to derive its API/WS/token-scope — NOT
# its asset URLs. When no store is present we fall back to the single
# spa/index.html baked by the Dockerfile dashboard-build stage (server-only and
# legacy images), preserving prior behaviour.
class SpaController < ActionController::Base
  skip_forgery_protection

  CLIENT_COOKIE = "carbide_client".freeze

  def show
    build = resolve_build
    if build&.index_exist?
      pin_cookie(build)
      return render_spa(build.read_index)
    end

    # Legacy / server-only fallback: a single baked build, or none.
    legacy = Rails.root.join("spa", "index.html")
    return render_spa(File.read(legacy)) if File.exist?(legacy)

    return redirect_to("/about") if request.path == "/"

    render plain: "workspace SPA not built; see Dockerfile dashboard-build stage",
           status: :not_found
  end

  private

  def registry
    @registry ||= ClientRegistry.new
  end

  def resolve_build
    spec = params[:client].presence || request.cookies[CLIENT_COOKIE].presence
    registry.resolve(spec)
  rescue StandardError
    nil
  end

  # Pin the resolved build so subsequent history-mode loads stay on it until
  # the user picks another. Written at the Rack level because the app is
  # api_only (no ActionDispatch::Cookies middleware). Lax same-site keeps it on
  # normal navigations.
  def pin_cookie(build)
    response.set_cookie(CLIENT_COOKIE,
                        value: "#{build.name}@#{build.sha}", path: "/", same_site: :lax)
  end

  # Inject <base href> from Traefik's stripped prefix (e.g. "/w/2") so the
  # client derives its API/WS endpoints and token localStorage scope under the
  # workspace mount. Asset URLs in the document are already absolute.
  def render_spa(html)
    prefix = request.headers["X-Forwarded-Prefix"].to_s.sub(%r{/+\z}, "")
    base_href = prefix.empty? ? "/" : "#{prefix}/"
    base_tag = %(<base href="#{ERB::Util.html_escape(base_href)}">)
    html = html.sub(/<head(\s[^>]*)?>/, "\\0\n  #{base_tag}")
    render html: html.html_safe, layout: false, content_type: "text/html"
  end
end
