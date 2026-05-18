require 'json'

class Api::TerminalsController < Api::BaseController
  # POST /api/projects/:project_id/terminals
  def create
    project = current_user.projects.find(params[:project_id])

    ts = TerminalSession.create!(
      project:  project,
      owner:    current_user,
      pty_cmd:  params[:pty_cmd] || '/bin/bash',
      cols:     params[:cols] || 80,
      rows:     params[:rows] || 24,
      status:   'starting'
    )

    # Token already has project scope; include terminal_id so client can join
    token = WorkerTokenIssuer.issue!(user: current_user, project: project, terminal: ts)

    render json: { terminal_id: ts.id, token: token }
  end
end
