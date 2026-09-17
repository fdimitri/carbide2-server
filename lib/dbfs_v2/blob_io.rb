# frozen_string_literal: true
module DbfsV2
  # BlobIO — a stateless, S3-style byte interface over BINARY FileNodes.
  #
  # Deliberately NOT a server-side file descriptor. See decisions #25 for the
  # full reasoning; the short version:
  #
  #   * The whole model is immutable revisions + an explicit base. An fd is a
  #     mutable server cursor that hides WHICH version you are reading — exactly
  #     the thing that makes concurrent access safe.
  #   * Server fds do not survive a reconnect, a worker restart, or load
  #     balancing; you would have to re-establish them, at which point they are
  #     client state anyway.
  #   * A byte-offset fd would be a SECOND mutable coordinate system next to the
  #     line/char OT one, and the two would have to be reconciled.
  #
  # Instead every op is a pure function of (path, revision, offset): range reads
  # against a pinned version, whole-object writes that produce a new
  # content-addressed revision. For POSIX ergonomics there is a client-side
  # BlobCursor that emulates open/seek/read over a pinned revision.
  #
  # Binary content is NOT under OT (by design): concurrent writers are
  # last-write-wins at the revision level, exactly like the old DBFS.
  module BlobIO
    module_function

    # --- reads ---------------------------------------------------------------

    # Range read. `offset`/`length` are BYTES; length nil = to end. Past EOF
    # returns ''. Reads a specific `revision_id` if given, else the branch head.
    # Goes through the configured BlobStore, so a backend with native range
    # reads (S3 Range GET) is used directly.
    def read(store, path, offset: 0, length: nil, revision_id: nil, branch: Branch::MAIN)
      node = node!(store, path)
      rev = revision_id ? Revision.find_by(id: revision_id) : head_revision(node, branch)
      raise "no content at #{path}" unless rev
      digest = rev.payload['sha256']
      return slice(bytes_at(store, path, revision_id: revision_id, branch: branch), offset, length) if digest.nil?

      DbfsV2.blob_store.read_range(digest, offset, length)
    end

    def size(store, path, revision_id: nil, branch: Branch::MAIN)
      bytes_at(store, path, revision_id: revision_id, branch: branch).bytesize
    end

    # The content address (SHA-256) of the current (or given) revision.
    def digest(store, path, revision_id: nil, branch: Branch::MAIN)
      node = node!(store, path)
      rev = revision_id ? Revision.find_by(id: revision_id) : head_revision(node, branch)
      rev&.payload&.dig('sha256')
    end

    # --- writes (each produces a new writeBinary revision) -------------------

    # Create a new binary file. Returns the content address (SHA-256).
    def create(store, path, bytes, branch: Branch::MAIN, user_id: nil)
      bytes = bytes.to_s.b
      store.create_file(path, content: bytes, binary: true, branch: branch, user_id: user_id)
      Digest::SHA256.hexdigest(bytes)
    end

    # Replace the whole content of an existing binary file. Returns the new
    # content address (SHA-256).
    def write(store, path, bytes, branch: Branch::MAIN, user_id: nil)
      node!(store, path)
      bytes = bytes.to_s.b
      store.write_blob(path, bytes, branch: branch, user_id: user_id)
      Digest::SHA256.hexdigest(bytes)
    end

    # S3 `put`: create if absent, else replace.
    def put(store, path, bytes, branch: Branch::MAIN, user_id: nil)
      store.find(path) ? write(store, path, bytes, branch: branch, user_id: user_id)
                       : create(store, path, bytes, branch: branch, user_id: user_id)
    end

    # Append bytes to the end (read-modify-write -> one new revision). Returns
    # the new content address.
    def append(store, path, bytes, branch: Branch::MAIN, user_id: nil)
      cur = bytes_at(store, path, branch: branch)
      write(store, path, cur + bytes.to_s.b, branch: branch, user_id: user_id)
    end

    # Insert `bytes` at a byte `offset` (0..size), shifting the tail right.
    def insert(store, path, offset, bytes, branch: Branch::MAIN, user_id: nil)
      cur = bytes_at(store, path, branch: branch)
      off = clamp(offset, 0, cur.bytesize)
      write(store, path, cur.byteslice(0, off).to_s.b + bytes.to_s.b + cur.byteslice(off, cur.bytesize).to_s.b,
            branch: branch, user_id: user_id)
    end

    # Overwrite `length` bytes at `offset` with `bytes` (length nil = to end).
    # A splice, not a grow: content after the replaced range is kept.
    def overwrite(store, path, offset, length, bytes, branch: Branch::MAIN, user_id: nil)
      cur = bytes_at(store, path, branch: branch)
      off = clamp(offset, 0, cur.bytesize)
      len = length.nil? ? cur.bytesize - off : clamp(length, 0, cur.bytesize - off)
      write(store, path, cur.byteslice(0, off).to_s.b + bytes.to_s.b + cur.byteslice(off + len, cur.bytesize).to_s.b,
            branch: branch, user_id: user_id)
    end

    # Truncate to at most `length` bytes (no-op if already shorter).
    def truncate(store, path, length, branch: Branch::MAIN, user_id: nil)
      cur = bytes_at(store, path, branch: branch)
      len = clamp(length, 0, cur.bytesize)
      write(store, path, cur.byteslice(0, len).to_s.b, branch: branch, user_id: user_id)
    end

    # Copy via content addressing: the destination references the SAME blob
    # digest, so identical bytes are not stored twice. Returns the digest.
    def copy(store, src, dst, branch: Branch::MAIN, user_id: nil)
      bytes = bytes_at(store, src, branch: branch)
      if store.find(dst)
        write(store, dst, bytes, branch: branch, user_id: user_id)
      else
        create(store, dst, bytes, branch: branch, user_id: user_id)
      end
    end

    # --- internals -----------------------------------------------------------

    def node!(store, path)
      node = store.resolve(path) || store.find(path)
      raise "no such file: #{path}" unless node
      raise "not a file: #{path}" unless node.ftype == 'file'
      raise "not a binary file: #{path} (text uses the delta interface)" unless node.binary?
      node
    end

    def head_revision(node, branch)
      b = node.branches.find_by(name: branch) || node.branches.first
      b&.head_revision_id && Revision.find_by(id: b.head_revision_id)
    end

    def bytes_at(store, path, revision_id: nil, branch: Branch::MAIN)
      node!(store, path)
      b = store.read(path, revision_id: revision_id, branch: branch)
      raise "no content at #{path}" if b.nil?
      b.to_s.b
    end

    def slice(bytes, offset, length)
      off = clamp(offset, 0, bytes.bytesize)
      return (bytes.byteslice(off, bytes.bytesize) || ''.b).b if length.nil?
      return ''.b if length.to_i <= 0
      (bytes.byteslice(off, length) || ''.b).b
    end

    def clamp(v, lo, hi)
      [[v.to_i, lo].max, [hi, lo].max].min
    end
  end
end
