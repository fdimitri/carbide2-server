# frozen_string_literal: true
#
# Watcher — folding external disk writes back into the DB.
#
# Driven with fake inotify events (no kernel watches needed). The concern is
# that external content is absorbed faithfully: invalid UTF-8 is not silently
# mangled, and a text->binary promotion does not make earlier text revisions
# unreadable.
require_relative 'dbfs_v2_test_helper'
require 'tmpdir'

class WatcherTest < Minitest::Test
  include StoreTestHelpers
  Ev = Struct.new(:absolute_name, :flags)

  def setup
    @s = setup_store
    @root = Dir.mktmpdir
    @w = DbfsV2::Watcher.new(@s, @root)
  end

  def fire(rel, *flags) = @w.send(:handle, Ev.new(File.join(@root, rel), flags))

  # Latin-1 text has no NUL, so it takes the text path. Invalid bytes must be
  # preserved (e.g. treated as binary) or rejected cleanly -- never lossily
  # transcoded.
  def test_non_utf8_text_is_not_silently_lossy
    raw = "caf\xE9\n".b
    File.binwrite(File.join(@root, 'l1.txt'), raw)
    fire('l1.txt', :close_write)
    got = @s.read('/l1.txt')
    assert_equal raw, got.to_s.b
  end

  # The binary flag is per-node, but content type is per-revision. Promoting a
  # node to binary must not make its earlier text revisions unreadable.
  def test_history_survives_text_to_binary_promotion
    @s.create_file('/t', content: 'hello'); r_text = head(@s, '/t')
    File.binwrite(File.join(@root, 't'), "\x00\x01".b)
    fire('t', :close_write)
    assert_equal 'hello', @s.read('/t', revision_id: r_text)
  end

  # --- external delete (tombstoned, history preserved) -----------------------

  # An external :delete tombstones the node: it is hidden, but the revision DAG
  # survives and the path can be resurrected. (Before tombstones this destroyed
  # the node and cascaded its revisions — the one FS path that could wipe the
  # log. See decisions #24.)
  def test_external_delete_tombstones_and_preserves_history
    f = @s.create_file('/d', content: 'v1')
    @s.write('/d', d('insertDataSingleLine', { startLine: 0, startChar: 2, data: '!' }))
    before = Revision.where(file_node_id: f.id).count
    assert_operator before, :>=, 2
    DbfsV2::Flusher.new(@s, @root).flush_file('/d')   # materialize on disk

    File.delete(File.join(@root, 'd'))
    fire('d', :delete)

    assert_nil @s.find('/d'), 'node should be hidden'
    assert_equal before, Revision.where(file_node_id: f.id).count,
                 'revision DAG must survive an external delete'
    assert @s.find_any('/d').deleted?
  end

  # After an external delete, recreating at the same path RESURRECTS the node:
  # same id, history intact.
  def test_recreate_after_external_delete_resurrects
    f = @s.create_file('/d', content: 'old')
    old_id = f.id
    DbfsV2::Flusher.new(@s, @root).flush_file('/d')   # materialize on disk
    File.delete(File.join(@root, 'd'))
    fire('d', :delete)

    File.write(File.join(@root, 'd'), 'new')
    fire('d', :close_write)

    fresh = @s.find('/d')
    refute_nil fresh
    assert_equal old_id, fresh.id, 'recreate must resurrect the same node (history intact)'
    assert_equal 'new', @s.read('/d')
  end

  # --- flush -> watcher echo (Grok: suppress! is unused) ---------------------

  # A flush writes the file to disk; the resulting close_write carries identical
  # content and must NOT append a duplicate setContents. This is currently safe
  # only because content-equal is a no-op -- there is no real suppression.
  def test_flush_then_close_write_does_not_duplicate
    f = @s.create_file('/e', content: 'same')
    DbfsV2::Flusher.new(@s, @root).flush_file('/e')
    before = Revision.where(file_node_id: f.id).count

    fire('e', :close_write)
    assert_equal before, Revision.where(file_node_id: f.id).count,
                 'a flush echo appended a duplicate revision'
  end

  # A genuine external edit after a flush must still be imported.
  def test_real_edit_after_flush_is_imported
    f = @s.create_file('/e', content: 'same')
    DbfsV2::Flusher.new(@s, @root).flush_file('/e')
    File.write(File.join(@root, 'e'), 'changed externally')
    fire('e', :close_write)

    assert_equal 'changed externally', @s.read('/e')
    assert_operator Revision.where(file_node_id: f.id).count, :>, 1
  end

  # --- binary ingest wiring (decisions #28) ----------------------------------

  def test_binary_close_write_commits_a_writeBinary_revision
    raw = "\x00\x01\x02".b
    File.binwrite(File.join(@root, 'blob.bin'), raw)
    fire('blob.bin', :close_write)

    node = @s.find('/blob.bin')
    refute_nil node
    assert node.binary?
    assert_equal raw, @s.read('/blob.bin')
    assert_equal 'writeBinary', Revision.where(file_node_id: node.id).order(:timestamp).last.change_type
  end

  def test_binary_trailing_event_is_a_digest_noop
    raw = "\x00\x01\x02".b
    File.binwrite(File.join(@root, 'blob.bin'), raw)
    fire('blob.bin', :close_write)
    before = Revision.where(file_node_id: @s.find('/blob.bin').id).count

    fire('blob.bin', :close_write) # the trailing event from an inline write
    assert_equal before, Revision.where(file_node_id: @s.find('/blob.bin').id).count
  end

  def test_binary_change_commits_a_second_revision
    File.binwrite(File.join(@root, 'b.bin'), "\x00A".b)
    fire('b.bin', :close_write)
    File.binwrite(File.join(@root, 'b.bin'), "\x00B".b)
    fire('b.bin', :close_write)

    assert_equal 2, Revision.where(file_node_id: @s.find('/b.bin').id).count
    assert_equal "\x00B".b, @s.read('/b.bin')
  end

  # --- read-guard mechanics (#3): drain before read; event during read wins ---

  def test_guard_drains_the_triggering_event_before_the_read
    w = DbfsV2::Watcher.new(@s, @root)
    abs = File.join(@root, 'x')
    w.send(:note_event, abs)            # the event that triggered the read
    w.send(:advance_to_read_start, abs) # drains it
    refute w.send(:read_changed?, abs), 'the triggering event must not discard the read'
  end

  def test_guard_flags_an_event_that_arrives_during_the_read
    w = DbfsV2::Watcher.new(@s, @root)
    abs = File.join(@root, 'x')
    w.send(:advance_to_read_start, abs)
    w.send(:note_event, abs)            # a write landed mid-read
    assert w.send(:read_changed?, abs), 'an event during the read must discard'
  end

  # --- overflow ---------------------------------------------------------------

  def test_overflow_is_recorded
    w = DbfsV2::Watcher.new(@s, @root)
    refute w.overflowed?
    w.send(:handle, Ev.new(File.join(@root, 'x'), [:q_overflow]))
    assert w.overflowed?, 'IN_Q_OVERFLOW marks the tree dirty for reconcile'
  end

end
