# REST API for the DBFS v2 project filesystem.
# All routes are scoped under /api/projects/:project_id/fs/...
#
# GET    /fs/tree                 — full file tree JSON (same shape as the worker's fs/tree)
# GET    /fs/content?path=        — text content at the main head (or ?revision=<uuid>)
# GET    /fs/stat?path=           — node metadata (size, revisions, posix, symlink)
# GET    /fs/blob?path=           — raw bytes: the live file on disk (Range-capable),
#                                   or ?revision=<uuid> for an archived revision
# GET    /fs/download?path=       — file bytes, or a directory as .tar.gz (from disk)
# POST   /fs/files                — create file   { path:, content:, mkdirp: }
# POST   /fs/dirs                 — create folder { path: } (mkdir -p)
# PATCH  /fs/rename               — rename        { path:, new_name: }
# DELETE /fs/entry                — delete (tombstone; history is kept) { path: }
# POST   /fs/upload               — multipart archive/file upload
# POST   /fs/import               — walk the working tree into DBFS (FsLoader)
#
# REST writes are not broadcast to connected editors (same as DBFS v1); the
# worker's flusher writes them to disk and clients pick them up on refresh.
class Api::FsController < Api::BaseController
  before_action :load_project

  def tree
    render json: ProjectFs.tree_json(@project.id)
  end

  def content
    node = find_node!(params[:path])
    return unless node
    return render json: { error: 'entry is a directory' }, status: :unprocessable_entity if node.ftype == 'folder'

    if params[:revision].present?
      content = store.read(node.path, revision_id: params[:revision])
      return render json: { path: node.path, revision: params[:revision], content: content.to_s }
    end
    target = node.resolve
    return render json: { error: 'dangling symlink' }, status: :unprocessable_entity unless target
    return render json: { error: 'is binary — use blob' }, status: :unprocessable_entity if target.binary?

    render json: { path: node.path, revision: ProjectFs.head_revision_id(target), content: store.read(node.path) }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'revision not found' }, status: :not_found
  end

  def create_file
    path = require_param!(:path)
    return unless path
    mkdirp = params[:mkdirp] == true || params[:mkdirp] == 'true'
    unless mkdirp || store.find(File.dirname(normalize(path)))
      return render json: { error: "Parent directory #{File.dirname(normalize(path))} does not exist" },
                    status: :unprocessable_entity
    end
    node = ProjectFs.ensure_file!(store, path, content: params[:content].to_s, user_id: current_user.id)
    render json: node_json(node), status: :created
  rescue ArgumentError, RuntimeError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create_dir
    path = require_param!(:path)
    return unless path
    node = ProjectFs.ensure_folder!(store, path, user_id: current_user.id)
    render json: node_json(node), status: :created
  rescue ArgumentError, RuntimeError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def rename
    path = require_param!(:path)
    return unless path
    new_name = require_param!(:new_name)
    return unless new_name
    node = find_node!(path)
    return unless node
    return render json: { error: 'new_name must be a single path segment' }, status: :unprocessable_entity if new_name.include?('/')

    old_path = node.path
    new_path = File.join(File.dirname(old_path), new_name)
    moved = store.move(old_path, new_path, user_id: current_user.id)
    rename_on_disk(old_path, new_path)
    render json: node_json(moved)
  rescue ArgumentError, RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy_entry
    path = require_param!(:path)
    return unless path
    node = find_node!(path)
    return unless node
    return render json: { error: 'cannot delete root' }, status: :unprocessable_entity if node.root?

    store.delete(node.path, user_id: current_user.id)
    # Mirror to disk. The worker's watcher sees the :delete, finds the node
    # already tombstoned, and does nothing.
    disk = ProjectFs.disk_path(root_path, node.path)
    FileUtils.rm_rf(disk) if File.exist?(disk) || File.symlink?(disk)
    head :no_content
  rescue => e
    Rails.logger.warn("destroy_entry failed: #{e.class}: #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/projects/:project_id/fs/stat?path=/some/path
  def stat
    return unless find_node!(params[:path])
    render json: store.stat(params[:path])
  end

  # GET /api/projects/:project_id/fs/blob?path=/img.png[&revision=<uuid>]
  # Live bytes come from the working tree on disk (the PVC is authoritative for
  # binaries; honours Range). A ?revision= reads the archived bytes for that
  # revision from DBFS instead.
  def blob
    node = find_node!(params[:path])
    return unless node
    return render json: { error: 'is a directory' }, status: :unprocessable_entity if node.ftype == 'folder'

    if params[:revision].present?
      bytes = store.read(node.path, revision_id: params[:revision]).to_s.b
      type  = Marcel::MimeType.for(StringIO.new(bytes), name: node.cur_name) rescue 'application/octet-stream'
      return send_data bytes, type: type, disposition: 'inline', filename: node.cur_name
    end

    disk = ProjectFs.disk_path(root_path, node.path)
    return render json: { error: 'not on disk' }, status: :not_found unless File.file?(disk)

    content_type = Marcel::MimeType.for(Pathname.new(disk)) rescue 'application/octet-stream'
    send_file disk, type: content_type, disposition: 'inline', filename: node.cur_name
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'revision not found' }, status: :not_found
  end

  # GET /api/projects/:project_id/fs/download?path=/src
  # A file streams its raw bytes (attachment); a directory (including root '/',
  # i.e. the whole project) is streamed as a .tar.gz relative to that directory.
  # Served from the working tree on disk.
  def download
    path = params[:path].to_s.strip
    path = '/' if path.empty?

    disk = ProjectFs.disk_path(root_path, path)
    return render json: { error: 'not found' }, status: :not_found unless File.exist?(disk)

    if File.directory?(disk)
      name = path == '/' ? 'project' : File.basename(path)
      archive = Tempfile.new(['carbide-download', '.tar.gz'])
      archive.binmode
      ProjectArchive.export_to(disk, archive)
      archive.flush
      send_file archive.path, type: 'application/gzip', disposition: 'attachment',
                 filename: "#{name}.tar.gz"
    else
      content_type = Marcel::MimeType.for(Pathname.new(disk)) rescue 'application/octet-stream'
      send_file disk, type: content_type, disposition: 'attachment', filename: File.basename(path)
    end
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/projects/:project_id/fs/upload
  # multipart/form-data:
  #   file: (required) .zip/.tar/.tar.gz/.tgz are extracted, anything else stored as-is
  #   dest: (optional) destination directory inside the project tree; defaults to '/'
  def upload
    uploaded = params[:file]
    if uploaded.blank? || !uploaded.respond_to?(:read)
      return render json: { error: 'file is required (multipart upload)' }, status: :unprocessable_entity
    end

    dest = params[:dest].presence || '/'
    importer = ArchiveImporter.new(
      project:   @project,
      user_id:   current_user.id,
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
  # When path is omitted, imports from the project's working tree. Text nodes
  # that already have history are left alone (DB wins).
  def import_from_disk
    root = params[:path].presence || root_path
    unless Dir.exist?(root)
      return render json: { error: "directory not found: #{root}" }, status: :unprocessable_entity
    end

    stats = FsLoader.new(project_id: @project.id, root_path: root, user_id: current_user.id, verbose: false).load!
    render json: { root_path: root, **stats }
  end

  private

  def load_project
    @project = current_user.projects.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'project not found' }, status: :not_found
  end

  def store
    @store ||= ProjectFs.store(@project.id)
  end

  def root_path
    @root_path ||= ProjectFs.root_path(@project)
  end

  def normalize(path)
    p = path.to_s.strip
    p = "/#{p}" unless p.start_with?('/')
    p = p.chomp('/')
    p.empty? ? '/' : p
  end

  def find_node!(path)
    node = store.find(path.to_s.strip)
    unless node
      render json: { error: 'not found' }, status: :not_found
      return nil
    end
    node
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
    nil
  end

  def rename_on_disk(old_path, new_path)
    from = ProjectFs.disk_path(root_path, old_path)
    to   = ProjectFs.disk_path(root_path, new_path)
    return unless File.exist?(from) || File.symlink?(from)

    FileUtils.mkdir_p(File.dirname(to))
    File.rename(from, to)
  rescue SystemCallError => e
    Rails.logger.warn("rename on disk failed #{from} -> #{to}: #{e.class}: #{e.message}")
  end

  def require_param!(key)
    val = params[key].to_s.strip
    if val.empty?
      render json: { error: "#{key} is required" }, status: :unprocessable_entity
      return nil
    end
    val
  end

  def node_json(node)
    { id: node.id, name: node.cur_name, path: node.path, type: node.ftype }
  end
end
