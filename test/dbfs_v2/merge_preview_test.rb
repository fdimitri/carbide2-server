# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# The human path: preview the three-way view, resolve, commit with both heads
# pinned (ADR-036); a head that moved refuses the resolution.
class MergePreviewTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
  end

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })
  def set(data)             = d('setContents', { data: data })

  def fork_and_conflict
    @s.create_file('/f', content: "one\ntwo\nthree\n")
    @s.branch('/f', 'feature')
    @s.write('/f', set("one\nTHEIRS\nthree\n"), branch: 'feature')
    @s.write('/f', set("one\nOURS\nthree\n"))
  end

  def test_preview_of_a_conflict_carries_all_three_sides_and_a_marked_start
    fork_and_conflict
    p = @s.merge_preview('/f', target: 'main', source: 'feature')
    refute p[:clean]
    assert_equal "one\ntwo\nthree\n",    p[:base]
    assert_equal "one\nOURS\nthree\n",   p[:ours]
    assert_equal "one\nTHEIRS\nthree\n", p[:theirs]
    assert_equal head(@s, '/f'),            p[:target_head]
    assert_equal head(@s, '/f', 'feature'), p[:source_head]
    assert_equal DbfsV2::Content.at(@s.find('/f'), p[:base_revision]), p[:base]
    refute_empty p[:conflicts]
    assert_equal 1, p[:conflict_count]
    assert_includes p[:merged], "<<<<<<< main\nOURS\n=======\nTHEIRS\n>>>>>>> feature\n"
    assert_equal [1, 6], p[:conflict_blocks].first.values_at(:start_line, :end_line)
  end

  def test_preview_of_a_clean_merge_is_what_merge_auto_commits
    @s.create_file('/f', content: "a\nb\nc\n")
    @s.branch('/f', 'feature')
    @s.write('/f', ins(0, 0, 'A'), branch: 'feature')
    @s.write('/f', ins(2, 0, 'C'))
    p = @s.merge_preview('/f', target: 'main', source: 'feature')
    assert p[:clean]
    assert_equal 0, p[:conflict_count]
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged]
    assert_equal p[:merged], @s.read('/f')
  end

  def test_resolution_commits_a_merge_pinned_at_both_heads
    fork_and_conflict
    p = @s.merge_preview('/f', target: 'main', source: 'feature')
    rev = @s.merge('/f', target: 'main', source: 'feature', resolved: "one\nBOTH\nthree\n",
                         expected_head: p[:target_head], expected_source_head: p[:source_head], user_id: 3)
    assert_equal "one\nBOTH\nthree\n", @s.read('/f')
    assert_equal p[:target_head], rev.parent_id
    assert_equal p[:source_head], rev.second_parent_id
    assert @s.merge_preview('/f', target: 'main', source: 'feature')[:clean], 'nothing left to merge'
  end

  def test_a_head_that_moved_during_resolution_is_refused
    fork_and_conflict
    p = @s.merge_preview('/f', target: 'main', source: 'feature')
    @s.write('/f', ins(0, 0, 'late '), branch: 'feature')
    assert_raises(DbfsV2::ConflictError) do
      @s.merge('/f', target: 'main', source: 'feature', resolved: "x\n",
                     expected_head: p[:target_head], expected_source_head: p[:source_head])
    end
    @s.write('/f', ins(0, 0, 'late '))
    assert_raises(DbfsV2::ConflictError) do
      @s.merge('/f', target: 'main', source: 'feature', resolved: "x\n", expected_head: p[:target_head])
    end
    assert_equal "late one\nOURS\nthree\n", @s.read('/f'), 'nothing was committed'
  end
end
