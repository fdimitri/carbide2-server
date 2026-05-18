require 'json'

class TerminalsController < ActionController::API
  # POST /projects/:project_id/terminals
  def create
    project = Project.find(params[:project_id])
    # Authentication/authorization TODO: ensure current_user has access

    ts = TerminalSession.create!(project: project, owner: current_user, pty_cmd: params[:pty_cmd] || '/bin/bash', cols: params[:cols] || 80, rows: params[:rows] || 24, status: 'starting')

    token = WorkerTokenIssuer.issue!(user: current_user, project: project, terminal: ts)

    render json: { terminal_id: ts.id, token: token }
  end

  private
  
  def current_user
    # Use Devise's current_user for authenticated requests
    super || User.first
  end
end
