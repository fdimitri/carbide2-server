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
    params.require(:project).permit(:name, :description)
  end

  def project_json(project)
    {
      id:          project.id,
      name:        project.name,
      description: project.description,
      created_at:  project.created_at
    }
  end
end
