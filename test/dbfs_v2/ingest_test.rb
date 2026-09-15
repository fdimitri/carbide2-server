# frozen_string_literal: true
#
# Ingest — the one function that turns a file's bytes into a binary revision.
# Covers both triggers (inline for DBFS writes, watcher for external), the
# idempotency rule, the guard/discard, and staging hygiene.
require_relative 'dbfs_v2_test_helper'
require 'tmpdir'

# Guard double: `changed?` is scripted, `on_read_start` is recorded.
class ScriptedGuard
  attr_reader :starts

  def initialize(changed: false)
    @changed = changed
    @starts = 0
  end

  def on_read_start = (@starts += 1)
  def changed? = @changed
end

class IngestTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
    @root = Dir.mktmpdir                       # simulates the working tree
    @cache_dir = Dir.mktmpdir                  # OUTSIDE the tree
    @cache = DbfsV2::BlobCache.new(@cache_dir)
    @blobs = DbfsV2::MemoryBlobStore.new
  end

  def teardown
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(@cache_dir)
  end

  def write_working(rel, bytes)
    p = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(p))
    File.binwrite(p, bytes)
    p
  end

  def ingest(path, source, guard: DbfsV2::Ingest::NoGuard.new, **opts)
    DbfsV2::Ingest.call(
      store: @s, path: path, source_path: source, staging_dir: @cache_dir,
      cache: @cache, blob_store: @blobs, guard: guard, **opts
    )
  end

  def digest_of(b) = Digest::SHA256.hexdigest(b)

  # --- both triggers, same function -----------------------------------------

  def test_external_ingest_commits_a_binary_revision
    @s.create_file('/asset.bin', binary: true)
    src = write_working('asset.bin', 'binary content v1')

    res = ingest('/asset.bin', src)

    assert_equal :committed, res[:status]
    assert_equal digest_of('binary content v1'), res[:digest]
    assert_equal 'writeBinary', res[:revision].change_type
    assert @blobs.exist?(res[:digest]), 'bytes went to the blob store'
    assert @cache.have?(res[:digest]), 'bytes are in the local cache'
    assert_equal res[:digest], @s.head_blob_digest('/asset.bin')
  end

  def test_inline_ingest_then_trailing_event_is_a_noop
    @s.create_file('/asset.bin', binary: true)
    src = write_working('asset.bin', 'same bytes')

    first = ingest('/asset.bin', src)
    assert_equal :committed, first[:status]

    # The watcher's trailing event re-ingests the same content -> no-op.
    second = ingest('/asset.bin', src)
    assert_equal :noop, second[:status]
    assert_equal 1, Revision.where(file_node_id: @s.find('/asset.bin').id).count
  end

  # --- idempotency -----------------------------------------------------------

  def test_changed_content_commits_a_new_revision
    @s.create_file('/asset.bin', binary: true)
    DbfsV2.with_blob_store(@blobs) do
      ingest('/asset.bin', write_working('asset.bin', 'v1'))
      res = ingest('/asset.bin', write_working('asset.bin_updated', 'v2'))

      assert_equal :committed, res[:status]
      assert_equal 2, Revision.where(file_node_id: @s.find('/asset.bin').id).count
      assert_equal 'v2'.b, @s.read('/asset.bin')
    end
  end

  # --- guard / discard -------------------------------------------------------

  def test_discard_when_guard_sees_a_modifying_event
    @s.create_file('/asset.bin', binary: true)
    src = write_working('asset.bin', 'torn maybe')
    guard = ScriptedGuard.new(changed: true)

    res = ingest('/asset.bin', src, guard: guard)

    assert_equal :discarded, res[:status]
    assert_equal 1, guard.starts, 'on_read_start was called (drains pending events)'
    assert_equal 0, Revision.where(file_node_id: @s.find('/asset.bin').id).count, 'nothing committed'
    refute @cache.have?(digest_of('torn maybe')), 'a discarded read never reaches the cache'
  end

  def test_guard_on_read_start_is_always_called
    @s.create_file('/asset.bin', binary: true)
    src = write_working('asset.bin', 'x')
    guard = ScriptedGuard.new(changed: false)
    ingest('/asset.bin', src, guard: guard)
    assert_equal 1, guard.starts
  end

  # --- staging hygiene -------------------------------------------------------

  def test_staging_temp_is_never_left_behind
    @s.create_file('/asset.bin', binary: true)
    ingest('/asset.bin', write_working('asset.bin', 'abc'))
    leftovers = Dir.children(@cache_dir).select { |f| f.start_with?('.staging.') }
    assert_empty leftovers, "staging temp left behind: #{leftovers.inspect}"
  end

  def test_discard_also_cleans_staging
    @s.create_file('/asset.bin', binary: true)
    src = write_working('asset.bin', 'abc')
    ingest('/asset.bin', src, guard: ScriptedGuard.new(changed: true))
    leftovers = Dir.children(@cache_dir).select { |f| f.start_with?('.staging.') }
    assert_empty leftovers
  end

  # --- seam: works over any blob store --------------------------------------

  def test_ingest_over_the_db_blob_store
    @s.create_file('/asset.bin', binary: true)
    src = write_working('asset.bin', 'to db')
    DbfsV2::Ingest.call(store: @s, path: '/asset.bin', source_path: src,
                        staging_dir: @cache_dir, cache: @cache,
                        blob_store: DbfsV2.blob_store)
    assert_equal 'to db'.b, @s.read('/asset.bin')
    assert_equal 1, Blob.where(digest: digest_of('to db')).count
  end

  # --- store-level commit_blob idempotency ----------------------------------

  def test_commit_blob_is_idempotent_against_head
    @s.create_file('/asset.bin', binary: true)
    d = @blobs.put('payload')
    r1 = @s.commit_blob('/asset.bin', digest: d, size: 7)
    refute_nil r1
    assert_nil @s.commit_blob('/asset.bin', digest: d, size: 7), 'same digest -> no-op'
    assert_equal 1, Revision.where(file_node_id: @s.find('/asset.bin').id).count
    assert_equal d, @s.head_blob_digest('/asset.bin')
  end
end
