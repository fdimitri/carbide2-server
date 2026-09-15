# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class MergeAutoTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_fast_forward_short_circuit
    @s.create_file('/f', content: "a\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'b' }), branch: 'feature')
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    assert res[:fast_forward]
    assert_equal "a\nb", @s.read('/f')
  end

  def test_disjoint_multicommit_auto_merge
    @s.create_file('/f', content: "a\nb\nc\nd\n")
    @s.branch('/f', 'feature')
    # main edits lines 0 and 1; feature edits lines 2 and 3 (all disjoint offsets)
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'M' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 1, data: 'N' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 2, startChar: 1, data: 'P' }), branch: 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 3, startChar: 1, data: 'Q' }), branch: 'feature')

    assert_equal [], @s.merge_conflicts?('/f', target: 'main', source: 'feature')
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    assert_equal "aM\nbN\ncP\ndQ\n", @s.read('/f')
  end

  def test_insert_overlap_auto_merges_via_ot
    @s.create_file('/f', content: 'X')
    @s.branch('/f', 'feature')
    # both insert at char 0 (overlap, but insert-scale -> safe, priority tie-break)
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }), branch: 'main', priority: 'a')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'B' }), branch: 'feature', priority: 'b')

    assert_equal [], @s.merge_conflicts?('/f', target: 'main', source: 'feature')
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    assert_equal 'ABX', @s.read('/f')
  end

  def test_overlapping_replace_is_conflict
    @s.create_file('/f', content: "def hello\n  1\nend\n")
    @s.branch('/f', 'feature')
    # both rewrite the whole function (overlapping replace regions)
    @s.write('/f', d('replaceDataMultiLine', { startLine: 0, startChar: 0, endLine: 2, endChar: 3, data: "def hello\n  2\nend" }), branch: 'main')
    @s.write('/f', d('replaceDataMultiLine', { startLine: 0, startChar: 0, endLine: 2, endChar: 3, data: "def hello\n  3\nend" }), branch: 'feature')

    confs = @s.merge_conflicts?('/f', target: 'main', source: 'feature')
    refute_empty confs
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    refute res[:merged]
    assert_equal 'conflict', res[:reason]
    assert_equal confs, res[:conflicts]
  end

  def test_overlapping_setcontents_is_conflict
    @s.create_file('/f', content: "base\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('setContents', { data: "main\n" }), branch: 'main')
    @s.write('/f', d('setContents', { data: "feature\n" }), branch: 'feature')

    confs = @s.merge_conflicts?('/f', target: 'main', source: 'feature')
    refute_empty confs
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    refute res[:merged]
  end

  def test_auto_merge_commit_has_two_parents
    @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')

    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    rev = res[:rev]
    assert rev.merge_commit?
    assert rev.second_parent_id.present?
    # both 'm' (main) and 'f' (feature) survive; order is priority-tied, not asserted
    assert_includes ["x\nmf", "x\nfm"], @s.read('/f')
  end
end

# A caller-supplied merge base (the fork point) must give the same result as the
# computed one, and a branch can be forked at a specific revision.
class MergeKnownBaseTest < Minitest::Test
  include DbfsV2TestHelpers

  def d(t, p) = DbfsV2::Delta.new(t, p)

  def build
    s = setup_store
    s.create_file('/f', content: "a\nb\nc\n")
    s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: '1' }))
    fork = s.find('/f').branches.find_by!(name: 'main').head_revision_id
    s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'M' }))
    s.branch('/f', 'feat', at_revision: fork)
    assert_equal "a1\nb\nc\n", s.read('/f', branch: 'feat')
    s.write('/f', d('insertDataSingleLine', { startLine: 2, startChar: 1, data: 'F' }), branch: 'feat')
    [s, fork]
  end

  def test_known_base_matches_computed_base
    s1, _ = build
    s2, fork = build
    computed = s1.merge('/f', target: 'main', source: 'feat', auto: true)
    known    = s2.merge('/f', target: 'main', source: 'feat', auto: true, base_id: fork)
    assert computed[:merged] && known[:merged]
    assert_equal computed[:content], known[:content]
    assert_equal "Ma1\nb\ncF\n", known[:content]
  end

  def test_branch_at_a_foreign_revision_is_refused
    s, _ = build
    other = setup_store
    other.create_file('/g', content: 'x')
    foreign = other.find('/g').branches.first.head_revision_id
    assert_raises(ActiveRecord::RecordNotFound) { s.branch('/f', 'bad', at_revision: foreign) }
  end
end

class MergePlantedSetContentsTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  # An auto-merge writes a setContents merge commit. A later concurrent edit
  # based on a PRE-merge revision must transform against it and converge, not
  # corrupt (setContents is now a single atomic/opaque prim).
  def test_stale_edit_against_merge_setcontents_converges
    f = @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    pre_merge_head = f.branches.find_by!(name: 'main').head_revision_id

    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    assert_equal 'setContents', res[:rev].change_type

    # concurrent stale edit based on the pre-merge head
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 1, data: '!' }), base_revision_id: pre_merge_head)

    # must not raise and must produce deterministic, well-formed content
    out = @s.read('/f')
    refute_nil out
    assert_includes out, 'x'
  end
end
