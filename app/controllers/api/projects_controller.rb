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
    project = Project.new(project_params)
    if project.save
      current_user.project_memberships.create!(project: project)
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
  # Updates the on-disk root path and optionally wipes the VFS.
  # Redirects to update_settings so root_path lives in project_settings.
  def set_root
    project   = find_project
    new_path  = params[:root_path].to_s.strip
    clean_vfs = ActiveModel::Type::Boolean.new.cast(params[:clean_vfs])

    return render json: { error: 'root_path is blank' }, status: :unprocessable_entity if new_path.empty?

    ActiveRecord::Base.transaction do
      if clean_vfs
        FileChange.where(directory_entry_id: project.directory_entries.select(:id)).delete_all
        project.directory_entries.delete_all
      end
      setting = project.project_setting || project.build_project_setting
      setting.update!(root_path: new_path)
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

  # GET /api/projects/:id/settings
  def settings
    project = find_project
    setting = project.project_setting || project.build_project_setting
    render json: settings_json(setting)
  end

  # PATCH /api/projects/:id/settings
  def update_settings
    project = find_project
    setting = project.project_setting || project.build_project_setting
    setting.assign_attributes(settings_params)
    setting.save!
    render json: settings_json(setting)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def find_project
    current_user.projects.find(params[:id] || params[:project_id])
  end

  def project_params
    params.require(:project).permit(:name, :description)
  end

  def settings_params
    params.permit(:root_path, :flush_interval_s, :flush_bytes, :shell_image)
  end

  def project_json(project)
    setting = project.project_setting
    {
      id:          project.id,
      name:        project.name,
      description: project.description,
      root_path:   setting&.root_path,
      created_at:  project.created_at
    }
  end

  def settings_json(setting)
    {
      project_id:       setting.project_id,
      root_path:        setting.root_path,
      flush_interval_s: setting.flush_interval_s,
      flush_bytes:      setting.flush_bytes,
      shell_image:      setting.shell_image
    }
  end
end
