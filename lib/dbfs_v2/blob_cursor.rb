# frozen_string_literal: true
module DbfsV2
  # BlobCursor — a CLIENT-SIDE file-descriptor emulation over a pinned blob.
  #
  # The server holds no fd state (see BlobIO / decisions #25). This object pins
  # a specific revision (the head at open, or an explicit one) and serves
  # seek/read from that fixed version, so it behaves like a POSIX fd for reading
  # while staying version-addressed underneath: a concurrent write does not move
  # this cursor — it keeps reading the version it opened.
  #
  # Memory: holds the pinned bytes in memory (a snapshot). That is fine for
  # normal assets; a very large blob would want a ranged backing store.
  #
  #   cur = store.blob_cursor('/asset.bin')
  #   cur.read(4)          # => first 4 bytes
  #   cur.seek(-4, :end)   # => 4 from the end
  #   cur.read
  class BlobCursor
    attr_reader :path, :revision_id

    def initialize(store, path, revision_id: nil, branch: Branch::MAIN)
      @store = store
      @path = path
      node = BlobIO.node!(store, path)
      @revision_id = revision_id || BlobIO.head_revision(node, branch)&.id
      @bytes = BlobIO.bytes_at(store, path, revision_id: @revision_id, branch: branch)
      @pos = 0
      @closed = false
    end

    def size = @bytes.bytesize
    def tell = @pos
    def eof? = @pos >= size
    def closed? = @closed

    # whence: :set (default, absolute), :cur (relative to here), :end (from EOF).
    # Seeking past EOF is allowed (a subsequent read returns '').
    def seek(offset, whence = :set)
      @pos = case whence
             when :set then offset.to_i
             when :cur then @pos + offset.to_i
             when :end then size + offset.to_i
             else raise ArgumentError, "whence must be :set, :cur or :end (got #{whence.inspect})"
             end
    end

    def rewind = seek(0)

    # Read up to `length` bytes (nil = to EOF) from the current position,
    # advancing it. Returns '' at/after EOF.
    def read(length = nil)
      raise IOError, 'closed stream' if @closed
      length = size - @pos if length.nil?
      return ''.b if length <= 0 || @pos >= size

      out = (@bytes.byteslice(@pos, length) || ''.b).b
      @pos += out.bytesize
      out
    end

    # Whole pinned content, leaving the position at EOF.
    def read_all
      seek(0)
      read
    end

    def to_s = @bytes.b

    def close
      @closed = true
      nil
    end
  end
end
