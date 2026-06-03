# Public splash served at /. Front door for the cluster.
#
# Does NOT enumerate workspaces or projects — that would leak names to
# unauthenticated visitors. The actual login form, per-user dashboard,
# and project picker all already live inside the SPA at /w/<id>/, so
# this page is just a brand splash that hands off:
#
#   - "Sign in" button -> /w/1/login  (SPA login form)
#   - inline JS: if an auth_token is already in localStorage, jump
#     straight to /w/1/dashboard. Same origin as the SPA, so the
#     localStorage entry is visible here.
#
# When we eventually have multiple workspaces, the splash will stay
# small and the SPA dashboard will choose between them.
class LandingController < ActionController::Base
  WORKSPACE_PATH = '/w/1'.freeze

  def index
    html = <<~HTML
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Carbide2</title>
          <style>
            html, body { height: 100%; margin: 0; }
            body {
              font-family: system-ui, -apple-system, sans-serif;
              background: linear-gradient(135deg, #1a1a1a 0%, #2a2030 100%);
              color: #ddd;
              display: flex; align-items: center; justify-content: center;
            }
            main { text-align: center; max-width: 540px; padding: 2rem; }
            h1   { font-weight: 200; font-size: 4rem; margin: 0 0 0.5rem;
                   letter-spacing: 0.04em; color: #fff; }
            p.tag { font-size: 1.1rem; color: #aaa; margin: 0 0 2.5rem; }
            a.btn {
              display: inline-block; padding: 0.75rem 2rem;
              background: #6cb6ff; color: #111; border-radius: 4px;
              text-decoration: none; font-weight: 500; font-size: 1rem;
              transition: background 0.15s;
            }
            a.btn:hover { background: #8fc4ff; }
            footer { margin-top: 4rem; color: #555; font-size: 0.8rem; }
          </style>
        </head>
        <body>
          <main>
            <h1>Carbide2</h1>
            <p class="tag">Cloud-native development workspaces.</p>
            <a class="btn" href="#{ERB::Util.h(WORKSPACE_PATH)}/login">Sign in</a>
            <footer>carbide2-server &middot; #{ERB::Util.h(Rails.env)}</footer>
          </main>
          <script>
            // If the SPA has already signed this browser in, skip the splash
            // and jump straight to the dashboard. Same origin as the SPA so
            // localStorage is shared.
            try {
              if (localStorage.getItem('auth_token')) {
                window.location.replace(#{WORKSPACE_PATH.to_json} + '/dashboard');
              }
            } catch (_) { /* private mode, ignore */ }
          </script>
        </body>
      </html>
    HTML

    render html: html.html_safe
  end
end
