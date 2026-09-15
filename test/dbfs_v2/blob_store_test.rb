# frozen_string_literal: true
#
# BlobStore — the byte-store seam.
#
# The same operations must behave identically regardless of which backend is
# configured, so the backend can be swapped (Postgres bytea today; S3 or Ceph
# behind the same interface) without any caller changing.
require_relative 'dbfs_v2_test_helper'

class BlobStoreTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  def bin(path, bytes) = @s.create_file(path, content: bytes.to_s.b, binary: true)

  # --- the interface --------------------------------------------------------

  def test_base_interface_raises
    base = DbfsV2::BlobStore.new
    %i[put get].each do |m|
      assert_raises(NotImplementedError) { base.public_send(m, 'x') }
    end
  end

  def test_default_store_is_db_backed
    assert_instance_of DbfsV2::DbBlobStore, DbfsV2.blob_store
  end

  def test_db_store_put_get_exist_size_delete
    store = DbfsV2::DbBlobStore.new
    digest = store.put('hello'.b)
    assert_equal Digest::SHA256.hexdigest('hello'), digest
    assert_equal 'hello'.b, store.get(digest)
    assert store.exist?(digest)
    assert_equal 5, store.size(digest)
    assert_equal 1, Blob.where(digest: digest).count, 'db store indexes the blob'
    store.delete(digest)
    refute store.exist?(digest)
  end

  # --- the seam: the same IO behavior under any backend ---------------------

  def test_blob_io_round_trips_under_each_backend
    [DbfsV2::DbBlobStore.new, DbfsV2::MemoryBlobStore.new].each do |backend|
      DbfsV2.with_blob_store(backend) do
        s = setup_store
        s.create_file('/b', binary: true)
        DbfsV2::BlobIO.write(s, '/b', 'abcdefghij')
        assert_equal 'abcdefghij'.b, DbfsV2::BlobIO.read(s, '/b'), "#{backend.class} read"
        assert_equal 'cde'.b, DbfsV2::BlobIO.read(s, '/b', offset: 2, length: 3), "#{backend.class} range"
        assert_equal 10, DbfsV2::BlobIO.size(s, '/b')
      end
    end
  end

  def test_swapping_the_store_redirects_writes_and_reads
    mem = DbfsV2::MemoryBlobStore.new
    digest = nil
    DbfsV2.with_blob_store(mem) do
      digest = DbfsV2::BlobIO.put(@s, '/m', 'in memory')
      assert_equal 'in memory'.b, DbfsV2::BlobIO.read(@s, '/m')
      assert mem.exist?(digest), 'bytes went to the memory store'
      assert_equal 0, Blob.where(digest: digest).count, 'nothing written to the db store'
    end
    # Restored to the default store afterwards.
    assert_instance_of DbfsV2::DbBlobStore, DbfsV2.blob_store
  end

  # --- range read is overridable (native range instead of slice) ------------

  def test_read_range_default_slices_and_is_overridable
    mem = DbfsV2::MemoryBlobStore.new
    d = mem.put('0123456789')
    assert_equal '345'.b, mem.read_range(d, 3, 3)
    assert_equal '3456789'.b, mem.read_range(d, 3, nil)
    assert_equal ''.b, mem.read_range(d, 99, 3)

    calls = []
    spy = Class.new(DbfsV2::BlobStore) do
      define_method(:get) { |dd| calls << dd; '0123456789'.b }
    end.new
    assert_equal '34'.b, spy.read_range(d, 3, 2)
    assert_equal [d], calls, 'default read_range goes through get'
  end

  # --- content is read through the store ------------------------------------

  def test_revision_read_goes_through_the_store
    bin('/b', 'persisted')
    r = head(@s, '/b')
    mem = DbfsV2::MemoryBlobStore.new
    # The revision references a digest that only exists in the db store; a
    # different store must therefore NOT find it (proves reads route through it).
    DbfsV2.with_blob_store(mem) do
      assert_raises(RuntimeError) { @s.read('/b', revision_id: r) }
    end
    assert_equal 'persisted'.b, @s.read('/b', revision_id: r), 'default store still reads it'
  end
end
