# frozen_string_literal: true
#
# Live write path — OT applied in Store#apply_transformed!.
#
# These assert that a concurrent edit reaching an already-advanced branch head
# is transformed correctly: no committed revision is erased, split deltas are
# transformed in the right coordinate space, and an overlapping full rewrite is
# a surfaced conflict rather than a silent relocation.
require_relative 'dbfs_v2_test_helper'

class LiveOtTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  # A transform that SPLITS the incoming delta (delete around an insert) yields
  # two sequential deltas. Each must be transformed against the next
  # concurrent revision in its own coordinate space, not the shared `state`.
  def test_split_delta_then_second_concurrent_revision
    @s.create_file('/f', content: '0123456789'); r0 = head(@s, '/f')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 5, data: 'X' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 7, data: 'Y' }))
    @s.write('/f', d('deleteDataSingleLine', { startLine: 0, startChar: 2, endChar: 8 }), base_revision_id: r0)
    assert_equal '01XY89', @s.read('/f')
  end

  # An opaque op (pcre/setContents) with a stale base becomes a setContents
  # snapshot after the first concurrent rev; transforming THAT against later
  # revs can order it after them and clobber them. Lost committed revision.
  def test_stale_opaque_op_does_not_erase_later_committed_revisions
    @s.create_file('/f', content: 'abc'); r0 = head(@s, '/f')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 3, data: '1' }), priority: '0')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 4, data: '2' }), priority: '0')
    @s.write('/f', d('pcreReplaceSingleLine', { pattern: 'a', replacement: 'A' }), base_revision_id: r0, priority: 'z')
    assert_equal 'Abc12', @s.read('/f')
  end

  # A stale keystroke concurrent with an external setContents (watcher import,
  # merge commit) must survive at its intended position regardless of the
  # priority ordering.
  def test_stale_keystroke_vs_external_setcontents_is_not_hash_dependent
    outs = [%w[0 z], %w[z 0]].map do |kp, sp|
      s = setup_store
      s.create_file('/f', content: "hello\nworld"); r0 = head(s, '/f')
      s.write('/f', d('setContents', { data: "# header\nhello\nworld" }), priority: sp)
      s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 5, data: '!' }), base_revision_id: r0, priority: kp)
      s.read('/f')
    end
    assert_equal ["# header\nhello\nworld!"] * 2, outs
  end

  # base_revision_id: nil is a blind append: coordinates validated against the
  # head this process saw, applied to whatever head exists under the lock.
  def test_nil_base_does_not_apply_stale_coordinates_to_a_newer_head
    s = setup_store
    f = s.create_file('/f', content: 'a'); s.read('/f')
    fired = false
    me = self
    hook = Module.new do
      define_method(:validate_against!) do |buf|
        r = super(buf)
        unless fired
          fired = true
          me.foreign_write(f, DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'Z' }))
        end
        r
      end
    end
    delta = d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' })
    delta.singleton_class.prepend(hook)
    s.write('/f', delta)
    assert_equal 'Zab', replay_truth(f, head(s, '/f'))
  end
end
