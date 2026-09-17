# frozen_string_literal: true
require 'fileutils'
require 'etc'

module DbfsV2
  # Flusher — materialize DB **text** content onto the regular filesystem.
  #
  # Binaries are NOT flushed: binary bytes live in the content-addressed archive
  # (BlobStore) and, for the live working copy, on the PVC via the ingest path —
  # never written out from the DB. Writing them here would make the flusher a
  # second writer to the authoritative working area. (v1 also skipped them; this
  # restores that.) See decisions #28.
  #
  # Writes text content, applies POSIX mode/owner, and creates symlinks.
  # Ownership chown is best-effort (non-root workers get EPERM, swallowed).
  class Flusher
    attr_reader :root_path

    def initialize(store, root_path)
      @store = store
      @root_path = root_path.to_s.chomp('/')
    end

    def flush_file(path)
      node = @store.find(path)
      raise "no such node: #{path}" unless node
      node = node.resolve || node
      return nil if node.ftype == 'file' && node.binary?  # never flush binaries

      abs = disk_path(node.path)

      case node.ftype
      when 'folder'
        FileUtils.mkdir_p(abs)
      when 'file'
        FileUtils.mkdir_p(File.dirname(abs))
        content = @store.read(node.path)
        File.write(abs, content.to_s)
        node.update_columns(last_size: content.bytesize, mtime: Time.current, updated_at: Time.current)
      end
      apply_posix!(node, abs)
      abs
    end

    def flush_symlink(path)
      node = @store.find(path)
      raise "no such node: #{path}" unless node
      raise "not a symlink: #{path}" unless node.symlink?
      abs = disk_path(node.path)
      FileUtils.mkdir_p(File.dirname(abs))
      File.unlink(abs) if File.symlink?(abs) || File.exist?(abs)
      File.symlink(node.symlink_target, abs)
      abs
    end

    # Flush every text file + symlink in the project. Binaries are skipped.
    def flush_all
      written = 0
      FileNode.where(project_id: @store.project_id).each do |node|
        next if node.path == '/'
        if node.symlink?
          flush_symlink(node.path)
        elsif node.ftype == 'file' && node.binary?
          next # binary: not flushed (see class comment)
        else
          flush_file(node.path)
        end
        written += 1
      end
      written
    end

    def disk_path(srcpath)
      # Defense in depth: resolve and verify the joined path stays inside the
      # root, so a traversal segment (if one ever reaches here) cannot escape.
      full = File.expand_path(File.join(@root_path, srcpath.sub(%r{\A/}, '')))
      root = File.expand_path(@root_path)
      unless full == root || full.start_with?(root + File::SEPARATOR)
        raise ArgumentError, "path escapes root: #{srcpath.inspect}"
      end
      full
    end

    private

    def apply_posix!(node, abs)
      if node.posix_mode
        File.chmod(node.posix_mode & 0o7777, abs) rescue nil
      end
      if node.owner || node.posix_group
        begin
          uid = node.owner      ? resolve_id(node.owner,      :user)  : nil
          gid = node.posix_group ? resolve_id(node.posix_group, :group) : nil
          File.chown(uid, gid, abs) if uid || gid
        rescue Errno::EPERM
          # non-root worker — silently skip
        end
      end
    end

    # Resolve an owner/group spec (name or numeric string) to a uid/gid, with
    # a best-effort fallback: try the passwd/group db, then a raw integer.
    def resolve_id(spec, kind)
      return nil if spec.nil? || spec == ''
      return spec.to_i if spec =~ /\A\d+\z/
      if kind == :user
        Etc.getpwnam(spec).uid
      else
        Etc.getgrnam(spec).gid
      end
    rescue ArgumentError
      nil
    end
  end
end
