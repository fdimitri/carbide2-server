# ArchiveImporter — extract an uploaded archive (zip, tar, tar.gz) or a single
# file and import each entry into a project's DBFS v2 tree.
#
# Used by POST /api/projects/:project_id/fs/upload.
#
# Text entries become (or replace the content of) text nodes. Binary entries
# take the DBFS binary-write path (ProjectFs.write_binary!): bytes are staged
# outside the working tree, renamed into place on the PVC, then ingested inline.
#
# Returns a stats hash: { files: Int, dirs: Int, skipped: Int, errors: [String] }
class ArchiveImporter

  Result = Struct.new(:files, :dirs, :skipped, :errors, keyword_init: true)

  def initialize(project:, user_id:, dest_path: '/', filename: nil)
    @project   = project
    @user_id   = user_id
    @dest_path = normalize_dir(dest_path)
    @filename  = filename.to_s
    @result    = Result.new(files: 0, dirs: 0, skipped: 0, errors: [])
    @total     = 0
    @count     = 0
    @store     = ProjectFs.store(project.id)
    setting    = project.project_setting
    # Per-project upload limits. nil = no limit (accept anything).
    @max_entry_bytes = setting&.upload_max_entry_bytes
    @max_total_bytes = setting&.upload_max_total_bytes
    @max_entries     = setting&.upload_max_entries
  end

  # Decide format from filename and extract from an open IO.
  def import!(io)
    ProjectFs.ensure_folder!(@store, @dest_path, user_id: @user_id)

    case @filename.downcase
    when /\.zip\z/                       then import_zip(io)
    when /\.tar\.gz\z/, /\.tgz\z/        then import_tar(Zlib::GzipReader.new(io))
    when /\.tar\z/                       then import_tar(io)
    else                                      import_single(io, @filename.presence || 'upload.bin')
    end

    @result
  end

  private

  def import_zip(io)
    Zip::File.open_buffer(io) do |zip|
      zip.each do |entry|
        break if hit_limit?
        next if entry.name.start_with?('__MACOSX/')

        target = join_dest(entry.name)
        if entry.directory?
          mkdir(target)
        else
          size = entry.size.to_i
          if @max_entry_bytes && size > @max_entry_bytes
            skip("entry too large: #{entry.name} (#{size} bytes)")
            next
          end
          data = entry.get_input_stream.read
          add_file(target, data)
        end
      end
    end
  rescue Zip::Error => e
    @result.errors << "zip parse error: #{e.message}"
  end

  def import_tar(io)
    Minitar::Reader.open(io) do |reader|
      reader.each_entry do |entry|
        break if hit_limit?

        target = join_dest(entry.full_name)
        if entry.directory?
          mkdir(target)
        else
          size = entry.size.to_i
          if @max_entry_bytes && size > @max_entry_bytes
            skip("entry too large: #{entry.full_name} (#{size} bytes)")
            next
          end
          data = entry.read
          add_file(target, data)
        end
      end
    end
  rescue StandardError => e
    @result.errors << "tar parse error: #{e.class}: #{e.message}"
  end

  def import_single(io, name)
    data = io.read
    if @max_entry_bytes && data.bytesize > @max_entry_bytes
      skip("file too large: #{name} (#{data.bytesize} bytes)")
      return
    end
    target = join_dest(File.basename(name))
    add_file(target, data)
  end

  def add_file(target, data)
    return skip("zip-slip rejected: #{target}") unless target.start_with?(@dest_path == '/' ? '/' : @dest_path + '/') || target == @dest_path
    @total += data.bytesize
    return skip("total size limit exceeded") if @max_total_bytes && @total > @max_total_bytes

    # Oversized text goes down the binary path too: it lands on disk and is
    # tracked metadata-only (ProjectFs.track_oversized!) instead of becoming a
    # multi-megabyte setContents.
    if ProjectFs.binary_bytes?(data) || data.bytesize > ProjectFs::MAX_FILE_SIZE
      ProjectFs.write_binary!(@project, @store, target, data, user_id: @user_id)
    else
      text = data.dup.force_encoding('UTF-8')
      node = @store.find(target)
      node = node.resolve || node if node
      if node
        # An upload over an existing file replaces its content. The setContents
        # is diffed against the head, so it lands as a mergeable edit; the
        # worker's flusher writes it to disk. Binary -> text demotes the node
        # (history stays readable: content type is per revision).
        node.update_columns(binary: false, updated_at: Time.current) if node.binary?
        delta = DbfsV2::Delta.new('setContents', { data: text })
        @store.write(node.path, delta, user_id: @user_id) unless @store.read(node.path) == text
      else
        @store.create_file(target, content: text, user_id: @user_id)
      end
    end
    @result.files += 1
    @count += 1
  rescue => e
    @result.errors << "#{target}: #{e.class}: #{e.message}"
  end

  def mkdir(target)
    ProjectFs.ensure_folder!(@store, target, user_id: @user_id)
    @result.dirs += 1
    @count += 1
  rescue => e
    @result.errors << "#{target}: #{e.class}: #{e.message}"
  end

  def skip(msg)
    @result.skipped += 1
    @result.errors << msg
  end

  def hit_limit?
    if @max_entries && @count >= @max_entries
      @result.errors << "entry count limit (#{@max_entries}) reached"
      return true
    end
    false
  end

  def join_dest(entry_name)
    # Reject absolute paths and parent traversal in entry names.
    clean = entry_name.to_s.gsub('\\', '/').sub(%r{\A/+}, '')
    parts = clean.split('/').reject { |p| p.empty? || p == '.' || p == '..' }
    return @dest_path if parts.empty?
    base = @dest_path == '/' ? '' : @dest_path
    "#{base}/#{parts.join('/')}"
  end

  def normalize_dir(p)
    s = p.to_s.strip
    s = "/#{s}" unless s.start_with?('/')
    s = s.chomp('/')
    s.empty? ? '/' : s
  end
end
