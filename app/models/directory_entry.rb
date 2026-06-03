# DirectoryEntry — virtual filesystem node for a project.
#
# ftype:   'file' | 'folder'
# srcpath: canonical path within project, e.g. '/src/app.rb'
# owner_id: id of the parent DirectoryEntry (nil for root)
#
# Mirrors the DirectoryEntry/DirectoryEntryCommandProcessor/DirectoryEntryHelper
# design from the original CARBIDE, adapted for Rails 8 conventions and
# multi-project support (project_id added to every entry).
require 'etc'

class DirectoryEntry < ApplicationRecord
  belongs_to :project
  belongs_to :owner,      class_name: 'DirectoryEntry', optional: true
  belongs_to :created_by, class_name: 'User',           optional: true, foreign_key: :created_by_id
  has_many   :children,   class_name: 'DirectoryEntry', foreign_key: :owner_id, dependent: :destroy
  has_many   :file_changes, dependent: :destroy

  validates :cur_name, presence: true
  validates :srcpath,  presence: true
  validates :ftype,    inclusion: { in: %w[file folder] }
  validates :srcpath,  uniqueness: { scope: :project_id }

  # Every project always has a root '/' folder entry (see .ensure_root!), so a
  # project is "empty" only when it has NO entries other than that root. Use
  # this for guards like import-into-empty-project rather than a bare
  # `where(project_id:).exists?`, which would always see the root and think the
  # project is non-empty.
  scope :content, -> { where.not(srcpath: '/') }

  def self.project_empty?(project_id)
    !content.where(project_id: project_id).exists?
  end

  # -------------------------------------------------------------------------
  # Content replay
  # -------------------------------------------------------------------------

  # Replay all FileChange records in order and return the current file content.
  # Equivalent to calcCurrent() in the original CARBIDE. Returns '' for binary
  # entries — their bytes live on disk only (see #13 in May30-Questions.md).
  def calc_current
    return '' if binary?
    doc = FsDocument.new
    file_changes.order(:revision, :id).each do |change|
      snake = camel_to_snake(change.change_type)

      if respond_to?("cmd_#{snake}", true)
        send("cmd_#{snake}", doc, change)
      else
        if doc.respond_to?("do_#{snake}")
          parsed = parse_change_data(change.change_data)
          doc.send("do_#{snake}", nil, parsed)
        end
      end
    end
    doc.get_contents
  end

  # Bounded byte read — useful for agent tool calls that need to peek at a
  # specific window of a file without loading the whole thing. For text
  # entries this still replays the full FileChange log (O(history)) but only
  # returns the requested slice. For binary entries we resolve the on-disk
  # path automatically via `disk_path` and read straight from disk.
  #
  # offset/length are in BYTES. Returns a (possibly empty) String in
  # ASCII-8BIT for binary, UTF-8 for text. Returns '' past EOF.
  def read_at(offset:, length:)
    offset = offset.to_i
    length = length.to_i
    return '' if length <= 0 || offset < 0
    if binary?
      dp = disk_path
      return '' unless dp && File.file?(dp)
      File.open(dp, 'rb') { |f| f.seek(offset); f.read(length) || '' }
    else
      content = calc_current
      content.byteslice(offset, length) || ''
    end
  end

  # Line-window read — the natural shape for agent tool calls ("show me
  # lines 40..80 of foo.rb"). `start_line` is 0-based, `line_count` is the
  # max number of lines to return. Returns a Hash:
  #   { lines: [..], start_line:, end_line:, total_lines:, eof: bool }
  # Raises ArgumentError for binary entries — line semantics don't apply
  # to opaque byte blobs (use read_at for those).
  def read_lines(start_line: 0, line_count: 200)
    raise ArgumentError, "read_lines is not valid for binary entries" if binary?
    start_line = [start_line.to_i, 0].max
    line_count = [line_count.to_i, 1].max
    all = calc_current.lines  # preserves trailing newlines
    total = all.length
    slice = all[start_line, line_count] || []
    end_line = start_line + slice.length  # exclusive
    {
      lines:       slice,
      start_line:  start_line,
      end_line:    end_line,
      total_lines: total,
      eof:         end_line >= total
    }
  end

  # Byte-window write — paired with read_at. Modes:
  #   :overwrite — replace `length` bytes starting at offset with `bytes`
  #                (length defaults to bytes.bytesize → straight overwrite)
  #   :insert    — splice `bytes` in at offset, shifting tail right
  #   :append    — ignore offset, write at EOF
  # For text entries the change is recorded as a FileChange (replayable).
  # For binary entries the disk file is rewritten in place and last_size/
  # mtime get refreshed. Returns the number of bytes written.
  def write_at(bytes:, offset: 0, length: nil, mode: :overwrite, user_id: nil)
    bytes = bytes.to_s
    if binary?
      dp = disk_path or raise "no on-disk path resolvable for project #{project_id}"
      FileUtils.mkdir_p(File.dirname(dp))
      case mode
      when :append
        File.open(dp, 'ab') { |f| f.write(bytes) }
      when :overwrite
        # length defaults to bytes.bytesize so caller can do a true overwrite
        # without computing it; pass an explicit length to truncate/extend.
        len = (length || bytes.bytesize).to_i
        existing = File.file?(dp) ? File.binread(dp) : ''.b
        head = existing.byteslice(0, offset.to_i) || ''.b
        tail = existing.byteslice(offset.to_i + len, existing.bytesize) || ''.b
        File.binwrite(dp, head + bytes.b + tail)
      when :insert
        existing = File.file?(dp) ? File.binread(dp) : ''.b
        head = existing.byteslice(0, offset.to_i) || ''.b
        tail = existing.byteslice(offset.to_i, existing.bytesize) || ''.b
        File.binwrite(dp, head + bytes.b + tail)
      else
        raise ArgumentError, "unknown mode #{mode.inspect}"
      end
      refresh_disk_stat!(dp)
      return bytes.bytesize
    end

    # Text path: synthesise a FileChange. We compute (line, char) from the
    # byte offset against the current contents — agent tools work in bytes
    # but the edit log is line/char addressed.
    cur = calc_current
    case mode
    when :append
      offset = cur.bytesize
      len    = 0
    when :insert
      len    = 0
    when :overwrite
      len    = (length || bytes.bytesize).to_i
    else
      raise ArgumentError, "unknown mode #{mode.inspect}"
    end
    sl, sc = byte_offset_to_line_char(cur, offset)
    el, ec = byte_offset_to_line_char(cur, offset + len) if len.positive?
    if len.positive?
      FileChange.append!(
        directory_entry_id: id, user_id: user_id,
        change_type: sl == el ? 'deleteDataSingleLine' : 'deleteDataMultiLine',
        change_data: { startLine: sl, startChar: sc, endLine: el, endChar: ec }.to_json,
        start_line:  sl, start_char: sc, end_line: el, end_char: ec
      )
    end
    unless bytes.empty?
      ml = bytes.include?("\n")
      FileChange.append!(
        directory_entry_id: id, user_id: user_id,
        change_type: ml ? 'insertDataMultiLine' : 'insertDataSingleLine',
        change_data: { startLine: sl, startChar: sc, data: bytes.dup.force_encoding('UTF-8') }.to_json,
        start_line:  sl, start_char: sc
      )
    end
    bytes.bytesize
  end

  # Line-window write — paired with read_lines. Replaces `line_count` lines
  # starting at `start_line` (0-based) with the array `lines`. Pass
  # `line_count: 0` to pure-insert before `start_line`. Newlines in `lines`
  # entries should be included by the caller (matches read_lines output).
  # Raises for binary entries.
  def write_lines(start_line:, line_count:, lines:, user_id: nil)
    raise ArgumentError, "write_lines is not valid for binary entries" if binary?
    start_line = [start_line.to_i, 0].max
    line_count = [line_count.to_i, 0].max
    lines = Array(lines).map(&:to_s)
    cur_lines = calc_current.lines
    head_bytes = cur_lines[0, start_line].to_a.sum(&:bytesize)
    del_bytes  = cur_lines[start_line, line_count].to_a.sum(&:bytesize)
    write_at(
      bytes:   lines.join,
      offset:  head_bytes,
      length:  del_bytes,
      mode:    :overwrite,
      user_id: user_id
    )
  end

  # Resolve the absolute on-disk path for this entry. Prefers the worker's
  # in-memory VFS_FLUSHERS map (avoids a DB hit + matches whatever path the
  # flusher is actively writing to); falls back to project settings when
  # called from the Rails side. Returns nil for the root folder or when no
  # root_path is configured.
  def disk_path
    return nil if srcpath == '/' || srcpath.blank?
    root =
      if defined?(::VFS_FLUSHERS) && (f = ::VFS_FLUSHERS[project_id])
        f.root_path
      else
        project.project_setting&.root_path.presence || project.default_root_path
      end
    return nil if root.blank?
    File.join(root.to_s.chomp('/'), srcpath.sub(%r{\A/}, ''))
  end

  # Convert a byte offset within `str` to a (line, char) pair using LF as the
  # line separator (matches how FileChange line/char columns are interpreted).
  def byte_offset_to_line_char(str, byte_off)
    byte_off = [byte_off.to_i, 0].max
    head = str.byteslice(0, byte_off) || ''
    line = head.count("\n")
    last_nl = head.rindex("\n")
    char = last_nl ? (head.bytesize - last_nl - 1) : head.bytesize
    [line, char]
  end
  private :byte_offset_to_line_char

  # Lightweight stat snapshot used by the explorer Properties panel and the
  # `fs/stat` WS command. `size` is the in-DB calculated current content size
  # for text files (which can differ from the on-disk last_size if the file is
  # dirty); for binary files we report last_size (== on-disk bytes) directly.
  def stat_hash
    rev_count = file_changes.count
    size = if binary?
             last_size.to_i
           else
             # Avoid double-replay: count bytes once.
             content = calc_current
             content.bytesize
           end
    {
      id:           id,
      path:         srcpath,
      name:         cur_name,
      type:         ftype,
      binary:       binary?,
      size:         size,
      revisions:    rev_count,
      posix_mode:   posix_mode,
      posix_owner:  posix_owner,
      posix_group:  posix_group,
      mtime:        mtime,
      created_at:   created_at,
      updated_at:   updated_at,
      created_by:   created_by_id,
      last_size:    last_size
    }
  end

  # Pull POSIX metadata + size + mtime off an on-disk file and persist.
  # No-op if disk_path doesn't exist or isn't a regular file. Owner/group
  # are resolved to names via Etc; falls back to numeric strings when the
  # uid/gid isn't in the passwd/group databases (common in containers).
  def refresh_disk_stat!(disk_path)
    return unless File.file?(disk_path) || File.directory?(disk_path)
    st     = File.stat(disk_path)
    uname  = (Etc.getpwuid(st.uid).name rescue st.uid.to_s)
    gname  = (Etc.getgrgid(st.gid).name rescue st.gid.to_s)
    update_columns(
      posix_mode:  st.mode & 0o7777,
      posix_owner: uname,
      posix_group: gname,
      last_size:   ftype == 'file' ? st.size : nil,
      mtime:       st.mtime,
      updated_at:  Time.current
    )
  rescue => e
    Rails.logger.warn "[DirectoryEntry##{id}] refresh_disk_stat! failed: #{e.class}: #{e.message}" if defined?(Rails)
  end

  # -------------------------------------------------------------------------
  # Filesystem query helpers
  # -------------------------------------------------------------------------

  # Returns tree hash suitable for JSON serialisation.
  # { id, name, path, type, children: [...] }
  def self.tree_for_project(project_id)
    entries  = where(project_id: project_id).to_a
    root     = entries.find { |e| e.srcpath == '/' && e.ftype == 'folder' }
    return [] unless root

    by_owner = entries.group_by(&:owner_id)
    build_tree_node(root, by_owner)
  end

  def self.find_by_project_and_path(project_id, srcpath)
    find_by(project_id: project_id, srcpath: srcpath)
  end

  # -------------------------------------------------------------------------
  # Filesystem mutation helpers
  # -------------------------------------------------------------------------

  # Ensure the root folder for a project exists, creating it if needed.
  def self.ensure_root!(project_id)
    find_or_create_by!(project_id: project_id, srcpath: '/', ftype: 'folder') do |e|
      e.cur_name = '/'
    end
  end

  # Create a file entry (and all intermediate directories if mkdirp: true).
  # When `binary: true`, the entry is created with NO FileChange row — the
  # bytes live on disk only (and are written there by the caller) and reads
  # go through the blob endpoint, not calc_current. See #13 in May30-Questions.md.
  # Returns the new DirectoryEntry or raises.
  def self.create_file!(project_id:, srcpath:, user_id: nil, data: nil, mkdirp: false, binary: false)
    srcpath = normalize(srcpath)
    raise ArgumentError, "srcpath must start with /" unless srcpath.start_with?('/')

    # Ensure parent directory exists
    parent_path = File.dirname(srcpath)
    parent = find_by_project_and_path(project_id, parent_path)
    if parent.nil?
      raise "Parent directory #{parent_path} does not exist" unless mkdirp
      mkdir_p!(project_id: project_id, srcpath: parent_path, user_id: user_id)
      parent = find_by_project_and_path(project_id, parent_path)
    end

    existing = find_by_project_and_path(project_id, srcpath)
    return existing if existing

    entry = create!(
      project_id:    project_id,
      owner_id:      parent.id,
      created_by_id: user_id,
      cur_name:      File.basename(srcpath),
      srcpath:       srcpath,
      ftype:         'file',
      binary:        binary,
      last_size:     binary && data ? data.bytesize : nil
    )

    if data && !data.empty? && !binary
      # Treat incoming bytes as UTF-8 and only scrub sequences that are
      # actually invalid. Calling .encode('UTF-8', replace: '') on an
      # ASCII-8BIT string strips every byte >= 0x80 — i.e. every multi-byte
      # UTF-8 char (en-dashes, em-dashes, smart quotes, accents). See the
      # matching fix in app/services/fs_loader.rb.
      data = data.dup.force_encoding('UTF-8')
      data = data.scrub('') unless data.valid_encoding?
      FileChange.create!(
        directory_entry_id: entry.id,
        user_id:            user_id || 1,
        change_type:        'setContents',
        change_data:        data,
        start_line:         0,
        start_char:         0,
        revision:           0
      )
    end

    entry
  end

  # Recursively create directories (mkdir -p).
  def self.mkdir_p!(project_id:, srcpath:, user_id: nil)
    srcpath = normalize(srcpath)
    return find_by_project_and_path(project_id, srcpath) if find_by_project_and_path(project_id, srcpath)

    # Walk from root down, creating any missing segment
    parts = srcpath.split('/').reject(&:empty?)
    current_path = ''
    parent = ensure_root!(project_id)

    parts.each do |part|
      current_path = "#{current_path}/#{part}"
      existing = find_by_project_and_path(project_id, current_path)
      if existing
        parent = existing
      else
        parent = create!(
          project_id:    project_id,
          owner_id:      parent.id,
          created_by_id: user_id,
          cur_name:      part,
          srcpath:       current_path,
          ftype:         'folder'
        )
      end
    end

    parent
  end

  # Rename this entry (files only for now; directory rename requires child srcpath rewrite).
  def rename!(new_name)
    raise "Directory rename not supported" if ftype == 'folder'
    parent_path  = File.dirname(srcpath)
    new_srcpath  = "#{parent_path}/#{new_name}".gsub('//', '/')
    update!(cur_name: new_name, srcpath: new_srcpath)
  end

  # -------------------------------------------------------------------------
  private
  # -------------------------------------------------------------------------

  # cmd_set_contents — replaces document content entirely.
  # Called by calc_current when change_type == 'setContents'.
  def cmd_set_contents(doc, change)
    data = change.change_data.to_s
    if data.include?("\n")
      doc.set_contents(data.split("\n", -1))
    else
      doc.set_contents([data])
    end
  end

  def self.build_tree_node(entry, by_owner)
    node = {
      id:      entry.id,
      name:    entry.cur_name,
      path:    entry.srcpath,
      type:    entry.ftype,
      binary: entry.binary?
    }
    if entry.ftype == 'folder'
      node[:children] = (by_owner[entry.id] || [])
        .sort_by { |e| [e.ftype == 'folder' ? 0 : 1, e.cur_name.downcase] }
        .map { |child| build_tree_node(child, by_owner) }
    end
    node
  end

  def camel_to_snake(str)
    str.gsub(/([A-Z])/) { "_#{$1.downcase}" }.sub(/^_/, '')
  end

  def parse_change_data(data)
    JSON.parse(data.to_s)
  rescue JSON::ParserError
    data
  end

  def self.normalize(path)
    path = path.to_s.strip
    path = "/#{path}" unless path.start_with?('/')
    path.chomp('/')
    path == '' ? '/' : path
  end
end
