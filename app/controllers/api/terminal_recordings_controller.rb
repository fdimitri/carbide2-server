# REST API for terminal recordings.
# Scoped under /api/projects/:project_id/recordings.
#
# GET    /api/projects/:project_id/recordings           — index
# GET    /api/projects/:project_id/recordings/:id       — single row
# GET    /api/projects/:project_id/recordings/:id/cast  — asciinema cast file
# DELETE /api/projects/:project_id/recordings/:id       — delete row + cast
class Api::TerminalRecordingsController < Api::BaseController
  before_action :load_project
  before_action :load_recording, only: [:show, :destroy, :cast]

  def index
    rows = TerminalRecording.for_project(@project.id).limit(500)
    render json: rows.map(&:to_list_entry)
  end

  def show
    render json: @recording.to_list_entry
  end

  # Stream the .cast file. We use send_file with a permissive Content-Type
  # so the client can either download it (Save As) or feed it directly to
  # asciinema-player via fetch().text() + parse().
  def cast
    path = @recording.absolute_file_path
    unless File.exist?(path)
      render json: { error: 'cast file missing on disk' }, status: :not_found
      return
    end
    send_file path,
              type:        'application/x-asciicast',
              disposition: params[:download] == 'true' ? 'attachment' : 'inline',
              filename:    "recording-#{@recording.id}.cast"
  end

  def destroy
    # Refuse to delete an in-progress recording — caller should stop it first.
    if @recording.status == 'recording'
      render json: { error: 'recording still in progress; stop it first' },
             status: :unprocessable_entity
      return
    end
    path = @recording.absolute_file_path
    @recording.destroy!
    File.delete(path) if File.exist?(path)
    head :no_content
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  private

  def load_project
    @project = current_user.projects.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'project not found' }, status: :not_found
  end

  def load_recording
    @recording = TerminalRecording.where(project_id: @project.id).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'recording not found' }, status: :not_found
  end
end
