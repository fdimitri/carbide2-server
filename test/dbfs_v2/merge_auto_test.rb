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

# A branch can be forked at a specific revision.
class BranchAtRevisionTest < Minitest::Test
  include DbfsV2TestHelpers

  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_branch_at_revision_starts_from_that_revision
    s = setup_store
    s.create_file('/f', content: "a\n")
    fork = s.find('/f').branches.find_by!(name: 'main').head_revision_id
    s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'M' }))
    s.branch('/f', 'feat', at_revision: fork)
    assert_equal "a\n", s.read('/f', branch: 'feat')
  end

  def test_branch_at_a_foreign_revision_is_refused
    s = setup_store
    s.create_file('/f', content: 'x')
    other = setup_store
    other.create_file('/g', content: 'y')
    foreign = other.find('/g').branches.first.head_revision_id
    assert_raises(ActiveRecord::RecordNotFound) { s.branch('/f', 'bad', at_revision: foreign) }
  end

  # Deleting a branch main fast-forwarded to must not take main's history with
  # it (revisions.branch_id cascades): the revisions are re-homed, main still
  # reads, and the branch can be recreated at its old head.
  def test_delete_branch_keeps_the_revisions_it_committed
    s = setup_store
    s.create_file('/f', content: "a\n")
    s.branch('/f', 'feat')
    s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'b' }), branch: 'feat')
    feat_head = s.find('/f').branches.find_by!(name: 'feat').head_revision_id
    assert s.merge('/f', target: 'main', source: 'feat', auto: true)[:fast_forward]
    assert_equal feat_head, s.find('/f').branches.find_by!(name: 'main').head_revision_id

    assert s.delete_branch('/f', 'feat')
    assert_equal %w[main], s.branches('/f').map { |b| b[:name] }
    assert Revision.exists?(id: feat_head), 'the revision main points at survives'
    assert_equal "a\nb", s.read('/f')
    assert_equal "a\nb", DbfsV2::Content.at(s.find('/f'), feat_head)

    s.branch('/f', 'feat', at_revision: feat_head)
    assert_equal "a\nb", s.read('/f', branch: 'feat')

    assert_raises(ArgumentError) { s.delete_branch('/f', 'main') }
    assert_raises(ActiveRecord::RecordNotFound) { s.delete_branch('/f', 'nope') }
  end
end

class MergeCommitStaleEditTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  # An auto-merge replays the source's edits onto the target as linear
  # revisions (the last one is the merge commit). A later concurrent edit based
  # on a PRE-merge revision transforms against those real edits and keeps
  # everyone's text.
  def test_stale_edit_against_merge_commit_converges
    f = @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    pre_merge_head = f.branches.find_by!(name: 'main').head_revision_id

    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    assert res[:replayed]
    assert res[:rev].merge_commit?

    # concurrent stale edit based on the pre-merge head, after the 'm'
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 1, data: '!' }), base_revision_id: pre_merge_head)

    out = @s.read('/f')
    assert_equal %w[! f m x], out.delete("\n").chars.sort, "lost or duplicated text: #{out.inspect}"
    assert_operator out.index('!'), :>, out.index('m'), "the stale edit moved before its anchor: #{out.inspect}"
  end
end
