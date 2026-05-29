# Tiny landing page served at /. Lists known workspaces with a link into
# each one. This Rails app is itself part of workspace 1; future deployments
# may move this into a dedicated control-plane service, but for now a single
# inline HTML response is enough to stop / from returning 404.
class LandingController < ActionController::Base
  def index
    workspaces = [
      { id: 1, name: 'Workspace 1', path: '/w/1/' },
    ]

    rows = workspaces.map { |w|
      %(<li><a href="#{w[:path]}">#{ERB::Util.h(w[:name])}</a> <span class="muted">#{w[:path]}</span></li>)
    }.join("\n")

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
            ul   { list-style: none; padding: 0; }
            li   { padding: 0.5rem 0; }
            a    { color: #6cb6ff; text-decoration: none; font-size: 1.1rem; }
            a:hover { text-decoration: underline; }
            .muted { color: #777; font-size: 0.85rem; margin-left: 0.5rem; }
            footer { margin-top: 3rem; color: #555; font-size: 0.8rem; }
          </style>
        </head>
        <body>
          <h1>Carbide2</h1>
          <p>Available workspaces:</p>
          <ul>
            #{rows}
          </ul>
          <footer>carbide2-server &middot; #{ERB::Util.h(Rails.env)}</footer>
        </body>
      </html>
    HTML

    render html: html.html_safe
  end
end
