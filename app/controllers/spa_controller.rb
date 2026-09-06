# Serves the SPA shell for any non-API, non-asset path so the Vue router's
# history-mode URLs (e.g. /login, /preferences) survive a hard reload. The
# static assets under /assets/* and /clients/* are served by
# ActionDispatch::Static before the router; this controller only runs for SPA
# route fallbacks.
#
# The Decider: the client is NOT baked into the image. It lives only in the
# content-addressed store (see ClientRegistry) — the MinIO static tier in
# cluster, or public/clients under test. This loader resolves a *pinned*
# build and serves that build's index.html. The choice comes from a `?client=`
# query param (which also pins a cookie for subsequent navigations) or the
# `carbide_client` cookie, defaulting to the newest build of the default family.
# The build's assets are already absolute (/clients/<family>/<sha>/...), so we
# only inject <base href> for the workspace prefix, which the client uses to
# derive its API/WS/token-scope — NOT its asset URLs.
class SpaController < ActionController::Base
  skip_forgery_protection

  CLIENT_COOKIE = "carbide_client".freeze

  # Family-agnostic escape hatch. A pin can point at a build whose picker is
  # itself broken, leaving no in-app way to un-pin. Any of these values in
  # ?client= unconditionally clears the pin and falls back to the newest build,
  # so a user can always recover by typing "?client=latest" in the URL bar
  # without editing cookies. Handled before any cookie is honored.
  RESET_SPECS = %w[latest newest reset clear default].freeze

  def show
    # An explicit ?client= is the build picker making a choice. Resolve it,
    # (un)pin the cookie, and 303 to a clean URL so the param never lingers in
    # the address bar. A "family@sha" spec pins that exact build; a family-only
    # spec ("carbide2-client" — the picker's "latest" entry) means "track the
    # newest" and clears any pin. A pick naming another pod's family is not
    # honored here (it is cleared and we fall back to our own family below).
    if (spec = params[:client].presence)
      if RESET_SPECS.include?(spec.downcase)
        clear_pin_cookie
        return redirect_to(clean_path, status: :see_other)
      end
      build = resolve_spec(spec)
      if build
        if spec.include?("@") && build.name == registry.default_family
          pin_cookie(build)
        else
          clear_pin_cookie
        end
        return redirect_to(clean_path, status: :see_other)
      end
    end

    build = resolve_build
    if build && (html = build.read_index)
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

  def resolve_spec(spec)
    registry.resolve(spec)
  rescue StandardError
    nil
  end

  def resolve_build
    # No explicit pick (handled in #show). The pin cookie is shared across the
    # whole origin: the control dashboard (path "/") and every workspace mount
    # (path "/w/<id>/") share the cookie name, and a path="/" cookie even
    # reaches "/w/<id>/". So only honor a cookie pin that resolves within THIS
    # pod's own family; otherwise serve the newest build of that family. The
    # default path intentionally writes NO cookie, so a plain reload after a new
    # build always tracks the newest — only an explicit pick sticks.
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

  # Clear any pin at this mount so the loader tracks the newest build again.
  def clear_pin_cookie
    prefix = request.headers["X-Forwarded-Prefix"].to_s.sub(%r{/+\z}, "")
    path = prefix.empty? ? "/" : "#{prefix}/"
    response.delete_cookie(CLIENT_COOKIE, path: path)
  end

  # The current request path minus the ?client= param, re-prefixed with the
  # stripped mount (X-Forwarded-Prefix) so the redirect lands back on this mount
  # (Traefik strips "/w/<id>" before it reaches us, so request.path lacks it).
  def clean_path
    prefix = request.headers["X-Forwarded-Prefix"].to_s.sub(%r{/+\z}, "")
    rest = request.query_parameters.except("client")
    path = "#{prefix}#{request.path}"
    path = "/" if path.empty?
    rest.empty? ? path : "#{path}?#{rest.to_query}"
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
