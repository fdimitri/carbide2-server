# frozen_string_literal: true
require 'fileutils'

module DbfsV2
  # BlobCache — a local, digest-named, content-addressed byte cache on disk.
  #
  # Because keys are content digests, a cached entry can never be STALE: a hit is
  # by definition the bytes for that digest. So there is no invalidation — only
  # eviction (bounded by total bytes, LRU by access time). That is the whole
  # reason a content-addressed store makes caching easy.
  #
  # MUST live OUTSIDE the watched working tree: it is written by us, and if it
  # were inside the tree the watcher would ingest its own cache files.
  #
  # Atomic writes: a temp file in the cache dir, renamed to the digest name only
  # after the bytes are complete. So a torn/partial write can never be visible
  # under a digest name.
  class BlobCache
    attr_reader :root, :max_bytes

    def initialize(root, max_bytes: 512 * 1024 * 1024)
      @root = root.to_s
      @max_bytes = max_bytes.to_i
      @lock = Mutex.new
      FileUtils.mkdir_p(@root)
    end

    def path(digest) = File.join(@root, digest)

    def have?(digest)
      File.file?(path(digest))
    end

    def read(digest)
      p = path(digest)
      return nil unless File.file?(p)
      File.binread(p)
    end

    def file_size(digest)
      p = path(digest)
      File.file?(p) ? File.size(p) : nil
    end

    def delete_file(digest)
      p = path(digest)
      File.delete(p) if File.file?(p)
      nil
    end

    # Write bytes under the digest name, atomically, then enforce the size
    # bound. Returns the digest.
    def write(digest, bytes)
      wrote = false
      @lock.synchronize do
        p = path(digest)
        next if File.file?(p) # already cached; content-addressed => identical
        tmp = "#{p}.tmp.#{Process.pid}.#{Thread.current.object_id}"
        File.binwrite(tmp, bytes)
        File.rename(tmp, p)
        wrote = true
      end
      evict! if wrote   # outside the lock: evict! takes @lock itself
      digest
    end

    # Total bytes currently cached.
    def size
      Dir.glob(File.join(@root, '*')).sum { |f| File.file?(f) ? File.size(f) : 0 }
    end

    # Evict least-recently-accessed entries until total <= max_bytes. Returns the
    # number of files removed.
    def evict!
      return 0 if @max_bytes <= 0
      @lock.synchronize do
        files = Dir.glob(File.join(@root, '*')).select { |f| File.file?(f) }
        total = files.sum { |f| File.size(f) }
        return 0 if total <= @max_bytes

        # Oldest access first. (atime may be noatime-mounted; mtime is the
        # fallback signal — either way it is only an eviction heuristic, never a
        # correctness input.)
        files.sort_by! { |f| [File.atime(f), File.mtime(f)] }
        removed = 0
        files.each do |f|
          break if total <= @max_bytes
          sz = File.size(f)
          File.delete(f)
          total -= sz
          removed += 1
        end
        removed
      end
    end
  end
end
