# Renders public/index.html for any non-API, non-asset path so the Vue
# router's history-mode URLs (e.g. /login, /preferences) survive a hard
# reload. The actual static assets under /assets/* are served by
# ActionDispatch::Static (public_file_server) before the router, so this
# controller only runs for SPA route fallbacks.
class SpaController < ActionController::Base
  skip_forgery_protection

  def show
    index = Rails.public_path.join('index.html')
    if File.exist?(index)
      render file: index.to_s, layout: false, content_type: 'text/html'
    else
      render plain: 'workspace SPA not built; see Dockerfile dashboard-build stage', status: :not_found
    end
  end
end
