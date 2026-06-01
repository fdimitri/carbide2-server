# REST API for the database-backed virtual filesystem.
# All routes are scoped under /api/projects/:project_id/fs/...
#
# GET    /api/projects/:project_id/fs/tree          — full file tree JSON
# GET    /api/projects/:project_id/fs/content       — file content (calc_current)
#          ?path=/src/app.rb
# POST   /api/projects/:project_id/fs/files         — create file
#          { path:, content: (optional) }
# POST   /api/projects/:project_id/fs/dirs          — create directory
#          { path: }
# PATCH  /api/projects/:project_id/fs/rename        — rename entry
#          { path:, new_name: }
# DELETE /api/projects/:project_id/fs/entry         — delete entry
#          { path: }
class Api::DirectoryEntriesController < Api::BaseController
  before_action :load_project

  def tree
    render json: DirectoryEntry.tree_for_project(@project.id)
  end

  def content
    entry = find_entry!(params[:path])
    return unless entry
    return render json: { error: 'entry is a directory' }, status: :unprocessable_entity if entry.ftype == 'folder'
    render json: { path: entry.srcpath, content: entry.calc_current }
  end

  def create_file
    path    = require_param!(:path)
    return unless path
    content = params[:content].to_s
    entry   = DirectoryEntry.create_file!(
      project_id: @project.id,
      srcpath:    path,
      user_id:    @current_user_id,
      data:       content,
      mkdirp:     params[:mkdirp] == true || params[:mkdirp] == 'true'
    )
    render json: entry_json(entry), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ArgumentError, RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create_dir
    path  = require_param!(:path)
    return unless path
    entry = DirectoryEntry.mkdir_p!(project_id: @project.id, srcpath: path, user_id: @current_user_id)
    render json: entry_json(entry), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def rename
    path     = require_param!(:path)
    return unless path
    new_name = require_param!(:new_name)
    return unless new_name
    entry    = find_entry!(path)
    return unless entry
    entry.rename!(new_name)
    render json: entry_json(entry)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy_entry
    path  = require_param!(:path)
    return unless path
    entry = find_entry!(path)
    return unless entry
    entry_path = entry.srcpath
    entry.destroy!

    # Mirror the delete to disk so the on-disk VFS stays in sync with DBFS.
    # Worker-driven deletes go through FsStore#handle_delete, which uses the
    # VFS suppress-set. The REST path is rarer (admin tools, scripts) so we
    # just remove the file/dir; the watcher will see a :delete inotify event
    # but `handle_event` bails early when the entry no longer exists.
    # Fixes #12 in May30-Questions.md.
    setting   = @project.project_setting
    root_path = setting&.root_path.presence || @project.default_root_path
    if root_path.present?
      disk_path = File.join(root_path, entry_path)
      FileUtils.rm_rf(disk_path) if File.exist?(disk_path)
    end

    head :no_content
  rescue => e
    Rails.logger.warn("destroy_entry disk rm failed: #{e.class}: #{e.message}")
    head :no_content
  end

  # GET /api/projects/:project_id/fs/stat?path=/some/path
  # Lightweight entry metadata for the explorer Properties panel (#5).
  def stat
    entry = find_entry!(params[:path])
    return unless entry
    render json: entry.stat_hash
  end

  # GET /api/projects/:project_id/fs/blob?path=/img.png
  # Streams the raw bytes of a binary (or any) entry straight from disk.
  # Honours Range: bytes=start-end for partial reads (image previews, big
  # downloads). Returns 404 if the file isn't on disk. See #13.
  def blob
    entry = find_entry!(params[:path])
    return unless entry
    return render json: { error: 'is a directory' }, status: :unprocessable_entity if entry.ftype == 'folder'

    setting   = @project.project_setting
    root_path = setting&.root_path.presence || @project.default_root_path
    disk_path = File.join(root_path.to_s, entry.srcpath)
    return render json: { error: 'not on disk' }, status: :not_found unless File.file?(disk_path)

    content_type = Marcel::MimeType.for(Pathname.new(disk_path)) rescue 'application/octet-stream'
    send_file disk_path,
              type:        content_type,
              disposition: 'inline',
              filename:    entry.cur_name
  end

  # POST /api/projects/:project_id/fs/upload
  # multipart/form-data:
  #   file:        (required) uploaded file; .zip/.tar/.tar.gz/.tgz are extracted, anything else stored as-is
  #   dest:        (optional) destination directory inside the project tree; defaults to '/'
  def upload
    uploaded = params[:file]
    if uploaded.blank? || !uploaded.respond_to?(:read)
      return render json: { error: 'file is required (multipart upload)' }, status: :unprocessable_entity
    end

    dest = params[:dest].presence || '/'
    importer = ArchiveImporter.new(
      project:   @project,
      user_id:   @current_user_id,
      dest_path: dest,
      filename:  uploaded.original_filename
    )
    result = importer.import!(uploaded.tempfile.tap(&:rewind))

    render json: {
      dest:     dest,
      filename: uploaded.original_filename,
      files:    result.files,
      dirs:     result.dirs,
      skipped:  result.skipped,
      errors:   result.errors
    }
  end

  # POST /api/projects/:project_id/fs/import
  # body: { path: '/optional/absolute/host/path' }
  # When path is omitted, imports from the project's configured root_path.
  # Wraps FsLoader; existing entries with FileChanges are skipped (DB wins).
  def import_from_disk
    root_path = params[:path].presence || @project.project_setting&.root_path || @project.default_root_path
    unless Dir.exist?(root_path)
      return render json: { error: "directory not found: #{root_path}" }, status: :unprocessable_entity
    end

    stats = FsLoader.new(
      project_id: @project.id,
      root_path:  root_path,
      user_id:    @current_user_id,
      verbose:    false
    ).load!

    render json: { root_path: root_path, **stats }
  end

  private

  def load_project
    @project = current_user.projects.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'project not found' }, status: :not_found
  end

  def find_entry!(path)
    entry = DirectoryEntry.find_by_project_and_path(@project.id, path.to_s.strip)
    unless entry
      render json: { error: 'not found' }, status: :not_found
      return nil
    end
    entry
  end

  def require_param!(key)
    val = params[key].to_s.strip
    if val.empty?
      render json: { error: "#{key} is required" }, status: :unprocessable_entity
      return nil
    end
    val
  end

  def entry_json(entry)
    { id: entry.id, name: entry.cur_name, path: entry.srcpath, type: entry.ftype }
  end
end
