# frozen_string_literal: true
#
# Keystroke hot path: with a warm DocumentCache, a read and a head-anchored
# write must not load the file's revision index (O(history)). Before this was
# pinned, every keystroke and every read replayed the whole log, so latency
# grew linearly with a file's edit history.
require_relative 'dbfs_v2_test_helper'

class HotPathTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
    @s.create_file('/h.txt', content: "hello\n")
    @s.read('/h.txt') # warm, as an open editor does
  end

  def without_revision_index
    orig = DbfsV2::Chain.method(:revision_index)
    DbfsV2::Chain.define_singleton_method(:revision_index) { |*| raise 'revision index loaded on the hot path' }
    yield
  ensure
    DbfsV2::Chain.define_singleton_method(:revision_index, orig)
  end

  def test_warm_read_does_not_load_history
    without_revision_index { assert_equal "hello\n", @s.read('/h.txt') }
  end

  def test_blind_and_head_anchored_writes_do_not_load_history
    without_revision_index do
      @s.write('/h.txt', d('insertDataSingleLine', { startLine: 0, startChar: 5, data: '!' }))
      @s.write('/h.txt', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: '>' }),
               base_revision_id: head(@s, '/h.txt'))
      assert_equal ">hello!\n", @s.read('/h.txt')
    end
    assert_equal ">hello!\n", replay_truth(@s.find('/h.txt'), head(@s, '/h.txt'))
  end

  # A stale base is NOT the hot path: it must still validate against the real
  # base content (cache is at the head, not at the base) and transform.
  def test_stale_base_still_validates_against_the_base
    base = head(@s, '/h.txt')
    @s.write('/h.txt', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'AAAA' }))
    # startChar 5 is valid in the base ("hello") and must land after "hello".
    @s.write('/h.txt', d('insertDataSingleLine', { startLine: 0, startChar: 5, data: '?' }), base_revision_id: base)
    assert_equal "AAAAhello?\n", @s.read('/h.txt')
  end

  def test_cache_does_not_answer_for_a_different_head
    node = @s.find('/h.txt')
    foreign_write(node, d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'F' }))
    assert_equal "Fhello\n", @s.read('/h.txt')
  end
end
