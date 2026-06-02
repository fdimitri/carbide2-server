# Renders public/index.html for any non-API, non-asset path so the Vue
# router's history-mode URLs (e.g. /login, /preferences) survive a hard
# reload. The actual static assets under /assets/* are served by
# ActionDispatch::Static (public_file_server) before the router, so this
# controller only runs for SPA route fallbacks.
class SpaController < ActionController::Base
  skip_forgery_protection

  def show
    index = Rails.root.join('app', 'spa', 'index.html')
    unless File.exist?(index)
      # No SPA bundle was built into this image — fall back to the
      # Rails landing page (server-only / dev runs without dashboard-build).
      return redirect_to('/about') if request.path == '/'
      render plain: 'workspace SPA not built; see Dockerfile dashboard-build stage', status: :not_found
      return
    end

    # Traefik's stripPrefix middleware sets X-Forwarded-Prefix to the
    # original path prefix (e.g. "/w/2") so the SPA (Vue Router + asset
    # URLs) can know where it is mounted in the browser. Inject it as
    # <base href="..."/> so:
    #   * Vite's compiled `./assets/...` URLs resolve under the prefix
    #   * Vue Router can read document.baseURI to set its base path
    html = File.read(index)
    prefix = request.headers['X-Forwarded-Prefix'].to_s
    prefix = prefix.sub(%r{/+\z}, '') # trim trailing slashes
    base_href = prefix.empty? ? '/' : "#{prefix}/"
    base_tag = %(<base href="#{ERB::Util.html_escape(base_href)}">)
    html = html.sub(/<head(\s[^>]*)?>/, "\\0\n  #{base_tag}")
    render html: html.html_safe, layout: false, content_type: 'text/html'
  end
end
