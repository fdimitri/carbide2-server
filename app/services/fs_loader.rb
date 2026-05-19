# FsLoader — recursively scan a directory on disk and import it into the
# database-backed virtual filesystem for a given project.
#
# Usage:
#   FsLoader.new(project_id: 1, root_path: '/home/user/myproject').load!
#
# Behaviour:
# - Creates the project root ('/') if it does not exist.
# - For each directory found: creates a 'folder' DirectoryEntry.
# - For each file found: creates a 'file' DirectoryEntry and a 'setContents'
#   FileChange containing the file's content, unless the entry already has
#   existing FileChanges (DB takes priority over disk in that case).
# - Skips binary files (detected by null-byte presence in first 8 KB).
# - Skips files / directories matching IGNORED_PATTERNS.
# - Logs progress to stdout.
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

  MAX_FILE_SIZE = 5 * 1024 * 1024  # 5 MB — skip very large files

  def initialize(project_id:, root_path:, user_id: nil, verbose: true)
    @project_id = project_id
    @root_path  = File.expand_path(root_path)
    @user_id    = user_id || 1
    @verbose    = verbose
    @stats      = { dirs: 0, files: 0, skipped: 0, existing: 0 }
  end

  def load!
    raise "Directory not found: #{@root_path}" unless Dir.exist?(@root_path)

    log "Importing #{@root_path} into project #{@project_id}"
    DirectoryEntry.ensure_root!(@project_id)

    walk(@root_path, '/')

    log "Done — #{@stats[:dirs]} dirs, #{@stats[:files]} files imported, " \
        "#{@stats[:existing]} already had changes (skipped content), " \
        "#{@stats[:skipped]} skipped."
    @stats
  end

  private

  def walk(disk_dir, virtual_prefix)
    Dir.foreach(disk_dir) do |name|
      next if name == '.' || name == '..'

      rel_path    = virtual_prefix == '/' ? "/#{name}" : "#{virtual_prefix}/#{name}"
      disk_path   = File.join(disk_dir, name)
      rel_for_pat = rel_path.sub(%r{\A/}, '')

      if IGNORED_PATTERNS.any? { |pat| pat.match?(rel_for_pat) }
        log "  skip (ignored): #{rel_path}"
        @stats[:skipped] += 1
        next
      end

      if File.directory?(disk_path)
        import_dir(rel_path)
        walk(disk_path, rel_path)
      elsif File.file?(disk_path)
        import_file(disk_path, rel_path)
      end
    end
  end

  def import_dir(srcpath)
    existing = DirectoryEntry.find_by_project_and_path(@project_id, srcpath)
    return existing if existing

    parent_path = File.dirname(srcpath)
    parent      = DirectoryEntry.find_by_project_and_path(@project_id, parent_path)
    return unless parent  # should not happen if we walk top-down

    DirectoryEntry.create!(
      project_id:    @project_id,
      owner_id:      parent.id,
      created_by_id: @user_id,
      cur_name:      File.basename(srcpath),
      srcpath:       srcpath,
      ftype:         'folder'
    )
    @stats[:dirs] += 1
    log "  dir:  #{srcpath}"
  end

  def import_file(disk_path, srcpath)
    entry = DirectoryEntry.find_by_project_and_path(@project_id, srcpath)

    if entry && entry.file_changes.any?
      @stats[:existing] += 1
      log "  skip (has changes): #{srcpath}"
      return entry
    end

    size = File.size(disk_path)
    if size > MAX_FILE_SIZE
      @stats[:skipped] += 1
      log "  skip (too large #{size}): #{srcpath}"
      return
    end

    content = File.read(disk_path, encoding: 'binary')
    if content[0, 8192].include?("\x00")
      @stats[:skipped] += 1
      log "  skip (binary): #{srcpath}"
      return
    end

    content = content.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')

    parent_path = File.dirname(srcpath)
    parent      = DirectoryEntry.find_by_project_and_path(@project_id, parent_path)
    return unless parent

    unless entry
      entry = DirectoryEntry.create!(
        project_id:    @project_id,
        owner_id:      parent.id,
        created_by_id: @user_id,
        cur_name:      File.basename(srcpath),
        srcpath:       srcpath,
        ftype:         'file'
      )
    end

    FileChange.create!(
      directory_entry_id: entry.id,
      user_id:            @user_id,
      change_type:        'setContents',
      change_data:        content,
      start_line:         0,
      start_char:         0,
      revision:           0,
      mtime:              File.mtime(disk_path)
    )

    @stats[:files] += 1
    log "  file: #{srcpath} (#{size} bytes)"
    entry
  end

  def log(msg)
    puts msg if @verbose
  end
end
