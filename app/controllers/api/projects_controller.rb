# Projects CRUD — owned by the authenticated user
class Api::ProjectsController < Api::BaseController
  def index
    projects = current_user.projects.order(created_at: :desc)
    render json: projects.map { |p| project_json(p) }
  end

  def show
    project = find_project
    render json: project_json(project)
  end

  def create
    project = current_user.projects.build(project_params)
    if project.save
      render json: project_json(project), status: :created
    else
      render json: { errors: project.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    project = find_project
    if project.update(project_params)
      render json: project_json(project)
    else
      render json: { errors: project.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    find_project.destroy
    head :no_content
  end

  # PATCH /api/projects/:id/set_root
  # Updates the on-disk root path for this project.
  # Optional param clean_vfs: true destroys all directory_entries so the
  # worker can re-scan the new directory on next startup.
  def set_root
    project  = find_project
    new_path = params[:root_path].to_s.strip

    return render json: { error: 'root_path is blank' }, status: :unprocessable_entity if new_path.empty?

    clean_vfs = ActiveModel::Type::Boolean.new.cast(params[:clean_vfs])

    ActiveRecord::Base.transaction do
      if clean_vfs
        # Two-query bulk delete — avoids loading every record into Ruby.
        # Delete file_changes first (FK constraint), then the entries themselves.
        FileChange.where(directory_entry_id: project.directory_entries.select(:id)).delete_all
        project.directory_entries.delete_all
      end
      project.update!(root_path: new_path)
    end

    render json: project_json(project)
  end

  # POST /api/projects/:id/ws_token
  # Returns a project-scoped JWT for the worker WebSocket connection
  def ws_token
    project = find_project
    token   = WorkerTokenIssuer.issue!(user: current_user, project: project)
    render json: { token: token, project_id: project.id }
  end

  private

  def find_project
    current_user.projects.find(params[:id] || params[:project_id])
  end

  def project_params
    params.require(:project).permit(:name, :description, :root_path)
  end

  def project_json(project)
    {
      id:          project.id,
      name:        project.name,
      description: project.description,
      root_path:   project.root_path,
      created_at:  project.created_at
    }
  end
end
