# frozen_string_literal: true
require 'digest'
require 'fileutils'

module DbfsV2
  # Ingest — the ONE function that turns a file's bytes into a DBFS binary
  # revision. Two triggers call it, and nothing else commits binary content:
  #
  #   * DBFS binary writes (incl. uploads): the caller writes a staging file,
  #     renames it into place, then calls ingest inline.
  #   * External writes: the watcher calls it on an inotify event.
  #
  # Steps (settled, see decisions #28):
  #   1. drain pending events (guard.on_read_start)
  #   2. copy source -> a staging temp file, hashing + counting as we go
  #   3. if the guard saw a modifying event during the read, DISCARD (the pending
  #      rerun ingests the newer state) — a lost intermediate state is accepted
  #   4. no-op if the digest equals the branch head's digest (idempotent)
  #   5. move the staged file into the local cache under its digest
  #   6. put the bytes into the BlobStore (bytes BEFORE the revision)
  #   7. commit a writeBinary revision referencing the digest
  #
  # The staging file lives in the cache directory (same filesystem), so the
  # rename in step 5 is atomic and a torn read can never appear under a digest
  # name. The cache/staging dir MUST be outside the watched tree.
  module Ingest
    module_function

    # guard: responds to #on_read_start and #changed?. A no-op guard is used for
    # the inline trigger (we own the file; nothing else can write it).
    def call(store:, path:, source_path:, staging_dir:, cache:, blob_store:,
             branch: Branch::MAIN, guard: NoGuard.new, user_id: nil)
      guard.on_read_start

      tmp = staged_temp(staging_dir)
      digest, size = copy_hash(source_path, tmp)

      if guard.changed?
        safe_unlink(tmp)
        return { status: :discarded }
      end

      head_digest = store.head_blob_digest(path, branch: branch)
      if head_digest == digest
        safe_unlink(tmp)
        return { status: :noop, digest: digest }
      end

      # Move into the cache under the digest, then store + commit.
      cache.write(digest, File.binread(tmp))
      safe_unlink(tmp)

      blob_store.put(cache.read(digest))

      rev = store.commit_blob(path, digest: digest, size: size, branch: branch, user_id: user_id)
      { status: :committed, digest: digest, size: size, revision: rev }
    end

    # Copy `src` -> `dst`, returning [sha256, byte_count]. Streaming: never holds
    # the whole file in memory, and the hash covers exactly the bytes written.
    def copy_hash(src, dst)
      sha = Digest::SHA256.new
      size = 0
      File.open(src, 'rb') do |inp|
        File.open(dst, 'wb') do |out|
          while (chunk = inp.read(65_536))
            sha.update(chunk)
            out.write(chunk)
            size += chunk.bytesize
          end
        end
      end
      [sha.hexdigest, size]
    end

    def staged_temp(staging_dir)
      FileUtils.mkdir_p(staging_dir)
      File.join(staging_dir, ".staging.#{Process.pid}.#{Thread.current.object_id}.#{rand(1 << 32)}")
    end

    def safe_unlink(path)
      File.delete(path) if File.file?(path)
    rescue StandardError
      nil
    end

    # Default guard: nothing changes during the read. Used by the inline trigger.
    class NoGuard
      def on_read_start = nil
      def changed? = false
    end
  end
end
