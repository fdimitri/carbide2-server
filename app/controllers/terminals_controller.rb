require 'json'

class TerminalsController < ActionController::API
  # GET /projects/:project_id/terminals
  def index
    project = Project.find(params[:project_id])
    terminals = project.terminal_sessions.map do |ts|
      {
        id: ts.id,
        pty_cmd: ts.pty_cmd,
        status: ts.status,
        cols: ts.cols,
        rows: ts.rows,
        created_at: ts.created_at
      }
    end
    render json: { terminals: terminals }
  end

  # GET /projects/:project_id/terminals/:id/token
  def token
    terminal = TerminalSession.find(params[:id])
    project = terminal.project
    
    token = WorkerTokenIssuer.issue!(user: current_user, project: project, terminal: terminal)
    render json: { token: token, terminal_id: terminal.id }
  end

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
