# frozen_string_literal: true
require 'digest'

module DbfsV2
  # BlobStore — the byte-store seam.
  #
  # Content-addressed: `put(bytes)` returns the SHA-256 digest, and every read
  # is by digest. That is the one property implementations MUST preserve, and it
  # is what makes a swap safe: a digest names exact bytes, so any backend that
  # returns those bytes for that key is correct.
  #
  # Why an interface rather than a choice:
  #
  #   * The bytes need a MULTI-NODE, HA home (a single ext4 PVC is not it).
  #     Object storage (S3/MinIO) and a distributed FS (Ceph) both provide HA;
  #     they differ in access shape (object API vs POSIX), not in whether they
  #     can back the store.
  #   * The archive's access pattern is object-shaped — immutable, put-once,
  #     read-many, dedup — so an object store fits it directly. A POSIX backend
  #     (Ceph/CephFS) fits too, and also gives the mirror direct file access, at
  #     the cost of running a distributed FS. Ceph is out of scope for the first
  #     prototype; the seam keeps the door open.
  #
  # Implementations:
  #   * DbBlobStore     — `blobs.content` bytea (default; transactional, small).
  #   * MemoryBlobStore — in-memory (tests / proves the seam).
  #   * (future) S3BlobStore, CephBlobStore — same interface.
  class BlobStore
    # Store `bytes` (ASCII-8BIT) and return its SHA-256 hex digest.
    def put(_bytes) = raise NotImplementedError, "#{self.class}#put"
    # Fetch the full bytes for `digest`. Raises if absent.
    def get(_digest) = raise NotImplementedError, "#{self.class}#get"
    def exist?(_digest) = raise NotImplementedError, "#{self.class}#exist?"
    def size(_digest) = raise NotImplementedError, "#{self.class}#size"
    def delete(_digest) = raise NotImplementedError, "#{self.class}#delete"

    # Optional: backends that support native range reads (S3 Range GET, a file
    # seek) override this. The default slices `get`, which is correct everywhere.
    def read_range(digest, offset, length)
      bytes = get(digest)
      off = [[offset.to_i, 0].max, bytes.bytesize].min
      return (bytes.byteslice(off, bytes.bytesize) || ''.b).b if length.nil?
      return ''.b if length.to_i <= 0
      (bytes.byteslice(off, length) || ''.b).b
    end
  end

  # Default backend: `blobs.content` bytea in Postgres. Bytes and the
  # content-index live in the same row, so a write is transactional with the
  # revision that references it (no orphan window). Right for small payloads;
  # see decisions #26 for the large-payload trade.
  class DbBlobStore < BlobStore
    def put(bytes)
      bytes = bytes.to_s.b
      digest = Digest::SHA256.hexdigest(bytes)
      Blob.find_or_create_by!(digest: digest) do |b|
        b.content = bytes
        b.size = bytes.bytesize
      end
      digest
    rescue ActiveRecord::RecordNotUnique
      digest
    end

    def get(digest)
      row = Blob.find_by(digest: digest)
      raise "missing blob #{digest}" unless row
      row.content_bytes
    end

    def exist?(digest) = Blob.where(digest: digest).exists?
    def size(digest) = Blob.find_by(digest: digest)&.size
    def delete(digest) = Blob.where(digest: digest).delete_all
  end

  # In-memory backend — used by tests to prove the seam swaps cleanly. Not
  # durable; drops everything on restart.
  class MemoryBlobStore < BlobStore
    def initialize = @rows = {}

    def put(bytes)
      bytes = bytes.to_s.b
      digest = Digest::SHA256.hexdigest(bytes)
      @rows[digest] ||= bytes
      digest
    end

    def get(digest)
      @rows.fetch(digest) { raise "missing blob #{digest}" }
    end

    def exist?(digest) = @rows.key?(digest)
    def size(digest) = @rows[digest]&.bytesize
    def delete(digest) = @rows.delete(digest)
  end

  # The active byte store. Swap it (e.g. to an S3 backend) without touching any
  # caller: everything goes through put/get by digest.
  class << self
    def blob_store
      @blob_store ||= DbBlobStore.new
    end

    attr_writer :blob_store

    def with_blob_store(store)
      prev = @blob_store
      @blob_store = store
      yield store
    ensure
      @blob_store = prev
    end
  end
end
