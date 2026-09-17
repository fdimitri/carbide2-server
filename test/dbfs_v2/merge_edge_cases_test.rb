# frozen_string_literal: true
#
# Merge edge cases.
#
# Auto-merge must handle the branches real work produces: merging the same
# branch twice, delete-vs-replace overlap, branches cut from an empty file, and
# opaque (pcre) or binary content. It must never raise where a conflict result
# is the right answer, and must never orphan a concurrent write.
require_relative 'dbfs_v2_test_helper'

class MergeEdgeCasesTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  # The most common branch workflow: merge feature, keep working, merge again.
  # The merge base must honour the merge commit's second parent, or feature's
  # already-merged edits are replayed a second time.
  def test_merging_the_same_branch_twice
    @s.create_file('/f', content: "1\n2\n3"); @s.branch('/f', 'feat')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'm' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 2, startChar: 1, data: 'A' }), branch: 'feat')
    assert @s.merge('/f', target: 'main', source: 'feat', auto: true)[:merged]
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 1, data: 'n' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 2, startChar: 2, data: 'B' }), branch: 'feat')
    res = @s.merge('/f', target: 'main', source: 'feat', auto: true)
    assert res[:merged]
    assert_equal "1m\n2n\n3AB", @s.read('/f')
  end

  # delete-vs-replace is not a conflict per ADR #7; the merge must either
  # conflict cleanly or produce the correct combined content (no inverted range).
  def test_auto_merge_delete_vs_overlapping_replace
    @s.create_file('/f', content: '0123456789'); @s.branch('/f', 'feat')
    @s.write('/f', d('deleteDataSingleLine', { startLine: 0, startChar: 2, endChar: 5 }))
    @s.write('/f', d('replaceDataSingleLine', { startLine: 0, startChar: 4, endChar: 7, data: 'X' }), branch: 'feat')
    res = @s.merge('/f', target: 'main', source: 'feat', auto: true)
    assert(!res[:merged] || res[:content] == '01X789', "got #{res[:content].inspect}")
  end

  # create_file with no content has no genesis revision, so a branch cut
  # immediately has a nil shared base. Auto-merge must not raise on that.
  def test_auto_merge_of_branches_cut_from_an_empty_file
    @s.create_file('/f'); @s.branch('/f', 'feat')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'm' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'f' }), branch: 'feat')
    res = @s.merge('/f', target: 'main', source: 'feat', auto: true)
    assert res[:merged]
    assert_includes %w[mf fm], @s.read('/f')
  end

  # An opaque (pcre) revision must not make auto-merge raise.
  def test_auto_merge_with_pcre_revision_does_not_raise
    @s.create_file('/f', content: "abc\n"); @s.branch('/f', 'feat')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }))
    @s.write('/f', d('pcreReplaceSingleLine', { pattern: 'b', replacement: 'B' }), branch: 'feat')
    res = @s.merge('/f', target: 'main', source: 'feat', auto: true)
    assert(!res[:merged] || res[:content] == "aBc\nm", "got #{res.inspect}")
  end

  # Binary content is opaque bytes: a diverged binary merge is a conflict, not a
  # raised exception.
  def test_diverged_binary_auto_merge_reports_conflict_instead_of_raising
    @s.create_file('/b', content: "\x00\x01".b, binary: true); @s.branch('/b', 'feat')
    @s.write_blob('/b', "\x00\x02".b)
    @s.write_blob('/b', "\x00\x03".b, branch: 'feat')
    res = @s.merge('/b', target: 'main', source: 'feat', auto: true)
    refute res[:merged]
  end

  # A fast-forward must not orphan a write landing on the target between the
  # ancestry check and the locked pointer move.
  def test_fast_forward_does_not_orphan_a_concurrent_target_write
    @s.create_file('/g', content: 'x'); @s.branch('/g', 'feat')
    @s.write('/g', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'F' }), branch: 'feat')
    g = @s.find('/g')
    orig = DbfsV2::Merge.method(:fast_forward?)
    fired = false
    me = self
    DbfsV2::Merge.define_singleton_method(:fast_forward?) do |*a|
      r = orig.call(*a)
      unless fired
        fired = true
        me.foreign_write(g, DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'M' }))
      end
      r
    end
    begin
      @s.merge('/g', target: 'main', source: 'feat')
    ensure
      DbfsV2::Merge.define_singleton_method(:fast_forward?, orig)
    end
    racer = Revision.find_by!(file_node_id: g.id, priority: 'foreign')
    reach = DbfsV2::Chain.reachable_ids(head(@s, '/g'), DbfsV2::Chain.revision_index(g))
    assert_includes reach, racer.id, 'concurrent main write was orphaned by the fast-forward'
  end
end
