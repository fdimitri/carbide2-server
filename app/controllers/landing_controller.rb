# Tiny landing page served at /. Intentionally does NOT enumerate
# workspaces — that would leak which workspaces exist on the cluster to
# unauthenticated visitors. The real per-user dashboard (list of
# workspaces the requesting user belongs to, behind auth) is a TODO; see
# the open design questions in chat for May 29 2026.
#
# For now: a single link into /w/1/ where the existing SPA login takes
# over. Once a real dashboard exists, swap the body for a redirect to it.
class LandingController < ActionController::Base
  def index
    html = <<~HTML
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Carbide2</title>
          <style>
            body { font-family: system-ui, sans-serif; background: #1e1e1e; color: #ddd;
                   margin: 0; padding: 3rem; }
            h1   { font-weight: 300; letter-spacing: 0.02em; }
            a    { color: #6cb6ff; text-decoration: none; font-size: 1.1rem; }
            a:hover { text-decoration: underline; }
            .muted { color: #777; font-size: 0.85rem; margin-top: 2rem; }
            footer { margin-top: 3rem; color: #555; font-size: 0.8rem; }
          </style>
        </head>
        <body>
          <h1>Carbide2</h1>
          <p><a href="/w/1/">Enter workspace &rarr;</a></p>
          <p class="muted">A real per-user dashboard is coming. For now, sign in inside the workspace.</p>
          <footer>carbide2-server &middot; #{ERB::Util.h(Rails.env)}</footer>
        </body>
      </html>
    HTML

    render html: html.html_safe
  end
end

