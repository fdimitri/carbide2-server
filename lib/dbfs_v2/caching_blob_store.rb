# frozen_string_literal: true
module DbfsV2
  # CachingBlobStore — wraps any BlobStore with a local BlobCache.
  #
  # Pure decorator: the inner store stays unaware of the cache. Reads check the
  # cache first (a digest hit is authoritative bytes, never stale), writes go
  # through to the inner store and populate the cache. Because keys are digests,
  # this is correct under any inner store — Postgres, S3, Ceph.
  class CachingBlobStore < BlobStore
    def initialize(inner, cache)
      @inner = inner
      @cache = cache
    end

    attr_reader :inner, :cache

    def put(bytes)
      bytes = bytes.to_s.b
      digest = @inner.put(bytes)
      @cache.write(digest, bytes)
      @cache.evict!
      digest
    end

    def get(digest)
      @cache.read(digest) || begin
        bytes = @inner.get(digest)
        @cache.write(digest, bytes)
        bytes
      end
    end

    def exist?(digest) = @cache.have?(digest) || @inner.exist?(digest)
    def size(digest)   = (@cache.file_size(digest) || @inner.size(digest))
    def delete(digest) = (@cache.delete_file(digest); @inner.delete(digest))

    # Prefer the cache (a local read); otherwise delegate to the inner store,
    # which may itself have a native ranged read (e.g. S3 Range GET).
    def read_range(digest, offset, length)
      bytes = @cache.read(digest)
      return super_if_inner_range(digest, offset, length) if bytes.nil?

      off = [[offset.to_i, 0].max, bytes.bytesize].min
      return (bytes.byteslice(off, bytes.bytesize) || ''.b).b if length.nil?
      return ''.b if length.to_i <= 0
      (bytes.byteslice(off, length) || ''.b).b
    end

    private

    def super_if_inner_range(digest, offset, length)
      @inner.read_range(digest, offset, length)
    end
  end
end
