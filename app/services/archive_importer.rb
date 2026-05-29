# ArchiveImporter — extract an uploaded archive (zip, tar, tar.gz) or a single
# file and import each entry into a project's DB-backed file tree via
# DirectoryEntry.create_file! / mkdir_p!.
#
# Used by POST /api/projects/:project_id/fs/upload.
#
# Returns a stats hash: { files: Int, dirs: Int, skipped: Int, errors: [String] }
require 'zip'
require 'minitar'
require 'zlib'
require 'stringio'

class ArchiveImporter
  MAX_ENTRY_BYTES = 10 * 1024 * 1024  # 10 MB per entry
  MAX_TOTAL_BYTES = 200 * 1024 * 1024 # 200 MB extracted total
  MAX_ENTRIES     = 5_000

  Result = Struct.new(:files, :dirs, :skipped, :errors, keyword_init: true)

  def initialize(project:, user_id:, dest_path: '/', filename: nil)
    @project   = project
    @user_id   = user_id
    @dest_path = normalize_dir(dest_path)
    @filename  = filename.to_s
    @result    = Result.new(files: 0, dirs: 0, skipped: 0, errors: [])
    @total     = 0
    @count     = 0
  end

  # Decide format from filename and extract from an open IO.
  def import!(io)
    DirectoryEntry.ensure_root!(@project.id)
    DirectoryEntry.mkdir_p!(project_id: @project.id, srcpath: @dest_path, user_id: @user_id) if @dest_path != '/'

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
          if size > MAX_ENTRY_BYTES
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
          if size > MAX_ENTRY_BYTES
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
    if data.bytesize > MAX_ENTRY_BYTES
      skip("file too large: #{name} (#{data.bytesize} bytes)")
      return
    end
    target = join_dest(File.basename(name))
    add_file(target, data)
  end

  def add_file(target, data)
    return skip("zip-slip rejected: #{target}") unless target.start_with?(@dest_path == '/' ? '/' : @dest_path + '/') || target == @dest_path
    @total += data.bytesize
    return skip("total size limit exceeded") if @total > MAX_TOTAL_BYTES

    # Decode best-effort; binary content survives as UTF-8 replacement chars.
    text = data.dup.force_encoding('UTF-8')
    text = text.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') unless text.valid_encoding?

    DirectoryEntry.create_file!(
      project_id: @project.id,
      srcpath:    target,
      user_id:    @user_id,
      data:       text,
      mkdirp:     true
    )
    @result.files += 1
    @count += 1
  rescue => e
    @result.errors << "#{target}: #{e.class}: #{e.message}"
  end

  def mkdir(target)
    DirectoryEntry.mkdir_p!(project_id: @project.id, srcpath: target, user_id: @user_id)
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
    if @count >= MAX_ENTRIES
      @result.errors << "entry count limit (#{MAX_ENTRIES}) reached"
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
