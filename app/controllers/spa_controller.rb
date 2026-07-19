# Serves the SPA shell for any non-API, non-asset path so the Vue router's
# history-mode URLs (e.g. /login, /preferences) survive a hard reload. The
# static assets under /assets/* and /clients/* are served by
# ActionDispatch::Static before the router; this controller only runs for SPA
# route fallbacks.
#
# The Decider: the client is NOT baked into the image. It lives only in the
# content-addressed store (see ClientRegistry) — the MinIO static tier in
# cluster, or public/clients in dev-native. This loader resolves a *pinned*
# build and serves that build's index.html. The choice comes from a `?client=`
# query param (which also pins a cookie for subsequent navigations) or the
# `carbide_client` cookie, defaulting to the newest build of the default family.
# The build's assets are already absolute (/clients/<family>/<sha>/...), so we
# only inject <base href> for the workspace prefix, which the client uses to
# derive its API/WS/token-scope — NOT its asset URLs.
class SpaController < ActionController::Base
  skip_forgery_protection

  CLIENT_COOKIE = "carbide_client".freeze

  def show
    build = resolve_build
    if build && (html = build.read_index)
      pin_cookie(build)
      return render_spa(html)
    end

    return redirect_to("/about") if request.path == "/"

    render plain: "workspace SPA not available; build + upload it to the static tier " \
                  "(scripts/build-client)",
           status: :not_found
  end

  private

  def registry
    @registry ||= ClientRegistry.new
  end

  def resolve_build
    # An explicit ?client= is a deliberate override (the build picker): honor
    # whatever family/sha it names.
    if (spec = params[:client].presence)
      return registry.resolve(spec)
    end

    # The pin cookie is shared across the whole origin: the control dashboard
    # (path "/") and every workspace mount (path "/w/<id>/") all use the same
    # cookie name, and a path="/" cookie is even sent to "/w/<id>/". So a pin
    # written by another mount (e.g. the dashboard's carbide2-control build)
    # must NOT be served here — only honor a cookie pin that resolves within
    # THIS pod's own family; otherwise serve the newest build of that family.
    fam = registry.default_family
    if (spec = request.cookies[CLIENT_COOKIE].presence)
      build = registry.resolve(spec)
      return build if build && build.name == fam
    end
    registry.newest(fam)
  rescue StandardError
    nil
  end

  # Pin the resolved build so subsequent history-mode loads stay on it until
  # the user picks another. Written at the Rack level because the app is
  # api_only (no ActionDispatch::Cookies middleware). Scoped to the mount path
  # (X-Forwarded-Prefix) so a workspace's pin stays on that workspace and never
  # overwrites the dashboard's (or another workspace's) pin. Lax same-site keeps
  # it on normal navigations.
  def pin_cookie(build)
    prefix = request.headers["X-Forwarded-Prefix"].to_s.sub(%r{/+\z}, "")
    path = prefix.empty? ? "/" : "#{prefix}/"
    response.set_cookie(CLIENT_COOKIE,
                        value: "#{build.name}@#{build.sha}", path: path, same_site: :lax)
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
