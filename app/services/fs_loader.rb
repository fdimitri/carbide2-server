# FsLoader — walk a project's working tree on disk and bring it into DBFS v2.
#
# Usage:
#   FsLoader.new(project_id: 1, root_path: '/srv/projects/<uuid>').load!
#
# Run by the worker at startup (before the flusher and watcher start), by the
# watcher's debounced reconcile sweep (load_dir!), by import_git, and by the
# fs:load rake task / POST fs/import.
#
# Per entry:
# - Directory: ensure a live folder node (resurrecting a tombstoned one).
# - Text file with no node, a tombstoned node, or a node with no revisions yet:
#   create/resurrect it with the disk content as its first setContents.
# - Text file whose node already has history: DB wins, content is left alone
#   (the flusher's first sweep writes the DB head back to disk). Same rule as
#   DBFS v1.
# - Binary file: ensure a binary node, then run DbfsV2::Ingest (inline, no
#   read guard — the watcher isn't running yet, or a sweep is re-covering what
#   inotify missed). Idempotent by digest.
# - Over ProjectFs::MAX_FILE_SIZE: tracked as a metadata-only binary node.
# - POSIX metadata (mode, owner, group, size, mtime) is copied from disk onto
#   every node it touches.
#
# Skips IGNORED_PATTERNS at the root and PRUNE_DIR_NAMES at any depth.
class FsLoader
  IGNORED_PATTERNS = [
    /\A\.git(\/|$)/,
    /\A\.DS_Store\z/,
    /\Anode_modules(\/|$)/,
    /\A\.bundle(\/|$)/,
    /\Atmp(\/|$)/,
    /\Alog(\/|$)/,
    /\Astorage(\/|$)/,
    /\.sqlite3\z/,
    /\.log\z/,
  ].freeze

  # Directories that must never enter DBFS, at ANY depth (the anchored
  # IGNORED_PATTERNS above only match at the project root). The VfsWatcher
  # mirrors this set so the two can't drift.
  PRUNE_DIR_NAMES = %w[.git node_modules .bundle].freeze

  def initialize(project_id:, root_path:, user_id: nil, verbose: true)
    @project_id = project_id
    @root_path  = File.expand_path(root_path)
    @user_id    = user_id || User.system.id
    @verbose    = verbose
    @store      = ProjectFs.store(project_id)
    @stats      = { dirs: 0, files: 0, skipped: 0, existing: 0 }
  end

  def load!
    raise "Directory not found: #{@root_path}" unless Dir.exist?(@root_path)

    log "Importing #{@root_path} into project #{@project_id}"
    ProjectFs.record_disk_stat!(@store.create_folder('/'), @root_path)
    walk(@root_path, '/')

    log "Done — #{@stats[:dirs]} dirs, #{@stats[:files]} files imported, " \
        "#{@stats[:existing]} already had history (content skipped), " \
        "#{@stats[:skipped]} skipped."
    @stats
  end

  # Import a single subtree — the directory at +disk_subpath+ and everything
  # under it — without re-walking from the project root. The VfsWatcher calls
  # this to sweep a directory whose contents inotify missed because the files
  # were written before the directory's own recursive watch went live (#72).
  # Idempotent and race-safe. Returns the stats hash.
  def load_dir!(disk_subpath)
    disk_subpath = File.expand_path(disk_subpath)
    unless disk_subpath == @root_path || disk_subpath.start_with?(@root_path + '/')
      raise "load_dir!: #{disk_subpath} is outside root #{@root_path}"
    end
    return @stats unless Dir.exist?(disk_subpath)

    virtual = srcpath_for(disk_subpath)
    import_dir(virtual, disk_subpath)
    log "Sweeping #{disk_subpath} (#{virtual}) into project #{@project_id}"
    walk(disk_subpath, virtual)
    @stats
  end

  private

  def srcpath_for(disk_path)
    return '/' if disk_path == @root_path
    rel = disk_path[@root_path.length..].to_s
    rel.start_with?('/') ? rel : "/#{rel}"
  end

  def walk(disk_dir, virtual_prefix)
    Dir.foreach(disk_dir) do |name|
      next if name == '.' || name == '..'

      rel_path    = virtual_prefix == '/' ? "/#{name}" : "#{virtual_prefix}/#{name}"
      disk_path   = File.join(disk_dir, name)
      rel_for_pat = rel_path.sub(%r{\A/}, '')

      if IGNORED_PATTERNS.any? { |pat| pat.match?(rel_for_pat) } ||
         (PRUNE_DIR_NAMES.include?(name) && File.directory?(disk_path))
        log "  skip (ignored): #{rel_path}"
        @stats[:skipped] += 1
        next
      end

      if File.directory?(disk_path)
        import_dir(rel_path, disk_path) && walk(disk_path, rel_path)
      elsif File.file?(disk_path)
        import_file(disk_path, rel_path)
      end
    end
  rescue Errno::ENOENT, Errno::EACCES => e
    log "  skip (unreadable dir #{disk_dir}): #{e.class}"
  end

  def import_dir(srcpath, disk_path)
    existing = @store.find(srcpath)
    node = ProjectFs.ensure_folder!(@store, srcpath, user_id: @user_id)
    unless existing
      @stats[:dirs] += 1
      log "  dir:  #{srcpath}"
    end
    ProjectFs.record_disk_stat!(node, disk_path)
    node
  rescue RuntimeError => e
    # A file node already sits at this path (e.g. a file was replaced by a
    # directory on disk). Leave it for the watcher/user; don't abort the walk.
    log "  skip (#{e.message})"
    @stats[:skipped] += 1
    nil
  end

  def import_file(disk_path, srcpath)
    size = File.size(disk_path)
    if size > ProjectFs::MAX_FILE_SIZE
      ProjectFs.track_oversized!(@store, srcpath, disk_path, user_id: @user_id)
      @stats[:skipped] += 1
      log "  skip content (too large #{size}): #{srcpath}"
      return
    end

    if ProjectFs.binary_file?(disk_path)
      import_binary(disk_path, srcpath)
    else
      import_text(disk_path, srcpath)
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent create (the live watcher racing a sweep) won; its import
    # stands.
    @stats[:existing] += 1
  end

  def import_text(disk_path, srcpath)
    node = @store.find(srcpath)
    target = node && (node.resolve || node)

    if target && !target.binary? && ProjectFs.head_revision_id(target)
      # DB wins for text with history.
      @stats[:existing] += 1
      log "  skip (has history): #{srcpath}"
      return target
    end

    content = File.read(disk_path, mode: 'rb')
    # Only drop sequences that are actually invalid (binary_file? already sent
    # non-UTF-8 content down the binary path, so this is belt and braces).
    content.force_encoding('UTF-8')
    content = content.scrub('') unless content.valid_encoding?

    if target
      target.update_columns(binary: false, updated_at: Time.current) if target.binary?
      @store.write(target.path, DbfsV2::Delta.new('setContents', { data: content }), user_id: @user_id) unless content.empty?
    else
      # create_file resurrects a tombstoned node at this path (same id, same DAG).
      target = @store.create_file(srcpath, content: content, user_id: @user_id)
    end
    ProjectFs.record_disk_stat!(target, disk_path)
    @stats[:files] += 1
    log "  file: #{srcpath} (#{content.bytesize} bytes)"
    target
  end

  def import_binary(disk_path, srcpath)
    node = ProjectFs.ensure_file!(@store, srcpath, binary: true, user_id: @user_id)
    node = node.resolve || node
    node.update_columns(binary: true, updated_at: Time.current) unless node.binary?

    cache = ProjectFs.blob_cache(@project_id)
    res = DbfsV2::Ingest.call(
      store: @store, path: node.path, source_path: disk_path,
      staging_dir: cache.root, cache: cache, blob_store: DbfsV2.blob_store,
      user_id: @user_id
    )
    ProjectFs.record_disk_stat!(node, disk_path)
    if res[:status] == :committed
      @stats[:files] += 1
      log "  file: #{srcpath} (#{res[:size]} bytes, binary)"
    else
      @stats[:existing] += 1
    end
    node
  end

  def log(msg)
    puts msg if @verbose
  end
end
