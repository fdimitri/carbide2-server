# frozen_string_literal: true
#
# Byte-store backends: BlobCache (local, digest-named), CachingBlobStore
# (decorator), and S3BlobStore (S3-shape, injected client).
require_relative 'dbfs_v2_test_helper'
require 'tmpdir'
require 'stringio'

# A minimal in-memory S3 client: put_object / get_object / head_object /
# delete_object, including Range GET. Enough to exercise S3BlobStore without the
# network or the aws-sdk.
class FakeS3Client
  Obj = Struct.new(:body) do
    def content_length = body.bytesize
  end

  PutResponse = Struct.new(:body)
  GetResponse = Struct.new(:body)

  def initialize = @store = {}

  def put_object(bucket:, key:, body:, range: nil)
    @store[[bucket, key]] = body.to_s.b
    PutResponse.new(body)
  end

  def get_object(bucket:, key:, range: nil)
    k = [bucket, key]
    raise "NoSuchKey #{key}" unless @store.key?(k)
    data = @store[k]
    if range && range =~ /bytes=(\d+)-(\d*)/
      lo = Regexp.last_match(1).to_i
      hi = Regexp.last_match(2).empty? ? data.bytesize - 1 : Regexp.last_match(2).to_i
      data = data.byteslice(lo, hi - lo + 1).to_s.b
    end
    GetResponse.new(StringIO.new(data))
  end

  def head_object(bucket:, key:)
    k = [bucket, key]
    raise "NotFound #{key}" unless @store.key?(k)
    Obj.new(@store[k])
  end

  def delete_object(bucket:, key:)
    @store.delete([bucket, key])
  end
end

class BlobBackendsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @cache = DbfsV2::BlobCache.new(File.join(@dir, 'cache'))
  end

  def teardown = FileUtils.remove_entry(@dir)

  def digest_of(bytes) = Digest::SHA256.hexdigest(bytes)

  # --- BlobCache --------------------------------------------------------------

  def test_cache_write_read_have_delete
    d = digest_of('hello')
    @cache.write(d, 'hello')
    assert @cache.have?(d)
    assert_equal 'hello'.b, @cache.read(d)
    assert_equal 5, @cache.file_size(d)
    @cache.delete_file(d)
    refute @cache.have?(d)
    assert_nil @cache.read(d)
  end

  def test_cache_write_is_atomic_no_temp_left
    d = digest_of('abcdef')
    @cache.write(d, 'abcdef')
    leftovers = Dir.children(@cache.root).reject { |f| f == d }
    assert_empty leftovers, "atomic write left temp files: #{leftovers.inspect}"
  end

  def test_cache_write_is_idempotent
    d = digest_of('same')
    @cache.write(d, 'same')
    @cache.write(d, 'same') # no-op
    assert_equal 'same'.b, @cache.read(d)
  end

  def test_cache_evicts_by_size
    cache = DbfsV2::BlobCache.new(File.join(@dir, 'c2'), max_bytes: 10)
    cache.write(digest_of('aaaaaa'), 'aaaaaa')
    cache.write(digest_of('bbbbbb'), 'bbbbbb')
    cache.write(digest_of('cccccc'), 'cccccc') # 18 > 10 -> evict
    assert_operator cache.size, :<=, 10
    assert_operator cache.evict!, :>=, 0
  end

  def test_cache_named_by_digest_on_disk
    d = digest_of('named')
    @cache.write(d, 'named')
    assert_equal File.join(@cache.root, d), @cache.path(d)
    assert File.file?(@cache.path(d))
  end

  # --- S3BlobStore (injected client) -----------------------------------------

  def test_s3_store_round_trip_and_sharded_keys
    client = FakeS3Client.new
    s3 = DbfsV2::S3BlobStore.new(client: client, bucket: 'carbide-blobs')
    d = s3.put('binary payload')
    assert_equal digest_of('binary payload'), d
    assert_equal 'binary payload'.b, s3.get(d)
    assert s3.exist?(d)
    assert_equal 14, s3.size(d)
    # key is sharded by digest, under the prefix
    assert_equal "blobs/#{d[0, 2]}/#{d[2, 2]}/#{d}", s3.key(d)
  end

  def test_s3_store_range_get
    s3 = DbfsV2::S3BlobStore.new(client: FakeS3Client.new, bucket: 'b')
    d = s3.put('0123456789')
    assert_equal '345'.b, s3.read_range(d, 3, 3)
    assert_equal '3456789'.b, s3.read_range(d, 3, nil)
  end

  def test_s3_store_exist_and_size_absent
    s3 = DbfsV2::S3BlobStore.new(client: FakeS3Client.new, bucket: 'b')
    refute s3.exist?(digest_of('nope'))
    assert_nil s3.size(digest_of('nope'))
  end

  def test_s3_store_satisfies_the_blob_io_generic_tests
    s3 = DbfsV2::S3BlobStore.new(client: FakeS3Client.new, bucket: 'b')
    assert_kind_of DbfsV2::BlobStore, s3
    # default read_range contract: slicing get
    d = s3.put('abcdefg')
    assert_equal 'cde'.b, s3.read_range(d, 2, 3)
  end

  # --- CachingBlobStore ------------------------------------------------------

  def test_caching_store_reads_through_and_populates_cache
    inner = DbfsV2::MemoryBlobStore.new
    store = DbfsV2::CachingBlobStore.new(inner, @cache)
    d = store.put('cached bytes')
    assert_equal 'cached bytes'.b, store.get(d)
    assert @cache.have?(d), 'put populated the cache'
    # A read is served from the cache even if the inner store is emptied.
    inner.delete(d)
    assert_equal 'cached bytes'.b, store.get(d)
  end

  def test_caching_store_eviction_on_put
    inner = DbfsV2::MemoryBlobStore.new
    cache = DbfsV2::BlobCache.new(File.join(@dir, 'c3'), max_bytes: 8)
    store = DbfsV2::CachingBlobStore.new(inner, cache)
    store.put('aaaaaaaa')
    store.put('bbbbbbbb')
    assert_operator cache.size, :<=, 8
  end
end
