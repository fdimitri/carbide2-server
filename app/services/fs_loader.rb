# FsLoader — recursively scan a directory on disk and import it into the
# database-backed virtual filesystem for a given project.
#
# Usage:
#   FsLoader.new(project_id: 1, root_path: '/home/user/myproject').load!
#
# Behaviour:
# - Creates the project root ('/') if it does not exist.
# - For each directory found: creates a 'folder' DirectoryEntry.
# - For each file found: creates a 'file' DirectoryEntry. Text files also get
#   an initial 'setContents' FileChange (skipped when the entry already has
#   FileChanges — DB takes priority over disk). Binary files are tracked as
#   DBFS entries with `binary: true` and NO FileChange — their bytes live on
#   disk only and are served via the blob endpoint (see #13 in May30-Questions.md).
# - Populates POSIX metadata (mode, owner, group, size, mtime) on every entry.
# - Skips files / directories matching IGNORED_PATTERNS.
# - Logs progress to stdout.
require 'etc'

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
    if existing
      existing.refresh_disk_stat!(File.join(@root_path, srcpath.sub(%r{\A/}, '')))
      return existing
    end

    parent_path = File.dirname(srcpath)
    parent      = DirectoryEntry.find_by_project_and_path(@project_id, parent_path)
    return unless parent  # should not happen if we walk top-down

    entry = DirectoryEntry.create!(
      project_id:    @project_id,
      owner_id:      parent.id,
      created_by_id: @user_id,
      cur_name:      File.basename(srcpath),
      srcpath:       srcpath,
      ftype:         'folder'
    )
    entry.refresh_disk_stat!(File.join(@root_path, srcpath.sub(%r{\A/}, '')))
    @stats[:dirs] += 1
    log "  dir:  #{srcpath}"
  end

  def import_file(disk_path, srcpath)
    entry = DirectoryEntry.find_by_project_and_path(@project_id, srcpath)

    if entry && (entry.file_changes.any? || entry.binary?)
      # DB wins for text files that already have history. For binary entries
      # there is no history but the bytes are authoritative on disk — just
      # refresh stat and move on.
      entry.refresh_disk_stat!(disk_path) if entry.binary?
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

    parent_path = File.dirname(srcpath)
    parent      = DirectoryEntry.find_by_project_and_path(@project_id, parent_path)
    return unless parent

    raw_head = File.binread(disk_path, [size, 8192].min)
    is_binary = raw_head.include?("\x00")

    if is_binary
      # Track as DBFS entry; bytes stay on disk. Served by the blob endpoint.
      unless entry
        entry = DirectoryEntry.create!(
          project_id:    @project_id,
          owner_id:      parent.id,
          created_by_id: @user_id,
          cur_name:      File.basename(srcpath),
          srcpath:       srcpath,
          ftype:         'file',
          binary:        true,
          last_size:     size
        )
      else
        entry.update_columns(binary: true, last_size: size, updated_at: Time.current)
      end
      entry.refresh_disk_stat!(disk_path)
      @stats[:files] += 1
      log "  file: #{srcpath} (#{size} bytes, binary)"
      return entry
    end

    content = File.read(disk_path, mode: 'rb')
    # Interpret bytes as UTF-8 and only drop sequences that are actually
    # invalid UTF-8. The previous .encode('UTF-8', ...) call treated the
    # ASCII-8BIT source as encoding-less and replaced EVERY byte >= 0x80
    # with '', which silently stripped en-dashes (–), em-dashes (—),
    # smart quotes, accents, etc. — even from valid UTF-8 source files.
    content.force_encoding('UTF-8')
    content = content.scrub('') unless content.valid_encoding?

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
    entry.refresh_disk_stat!(disk_path)

    @stats[:files] += 1
    log "  file: #{srcpath} (#{size} bytes)"
    entry
  end

  def log(msg)
    puts msg if @verbose
  end
end
