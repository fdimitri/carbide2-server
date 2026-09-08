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

  # GET /api/projects/:id/export — stream the on-disk project dir as .tar.gz.
  def export
    project = find_project
    root    = project_root(project)
    unless root && Dir.exist?(root)
      return render json: { error: 'no project directory' }, status: :unprocessable_entity
    end

    filename = "#{project.uuid.presence || 'project'}.tar.gz"
    archive  = Tempfile.new(['carbide-export', '.tar.gz'])
    archive.binmode
    ProjectArchive.export_to(root, archive)
    archive.flush
    send_file archive.path, type: 'application/gzip', disposition: 'attachment', filename: filename
  end

  # POST /api/projects/:id/import — multipart `file` (.tar.gz) extracted into the
  # project dir, then re-scanned into the DBFS so the explorer reflects it.
  def import
    project = find_project
    root    = project_root(project)
    unless root
      return render json: { error: 'no project directory' }, status: :unprocessable_entity
    end
    uploaded = params[:file]
    if uploaded.blank? || !uploaded.respond_to?(:read)
      return render json: { error: 'file is required (multipart .tar.gz)' }, status: :unprocessable_entity
    end

    stats = ProjectArchive.import_from(uploaded.tempfile.tap(&:rewind), root)

    # Re-scan disk → DBFS so the restored tree shows up in the explorer.
    scan = FsLoader.new(project_id: project.id, root_path: root,
                        user_id: current_user.id, verbose: false).load!

    render json: { root_path: root, archive: stats, scan: scan }
  rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError => e
    render json: { error: "invalid archive: #{e.message}" }, status: :unprocessable_entity
  end

  private

  # On-disk project root, mirroring the fs blob/import paths: explicit
  # project_setting.root_path wins, else the UUID-derived default.
  def project_root(project)
    setting = project.project_setting
    (setting&.root_path.presence || project.default_root_path).to_s.chomp('/').presence
  end

  def find_project
    current_user.projects.find(params[:id] || params[:project_id])
  end

  def project_params
    params.require(:project).permit(:name, :description)
  end

  def settings_params
    params.permit(:root_path, :flush_interval_s, :flush_bytes, :shell_image,
                  :agent_shell_peek_tail_bytes)
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
      shell_image:      setting.shell_image,
      agent_shell_peek_tail_bytes: setting.agent_shell_peek_tail_bytes
    }
  end
end
