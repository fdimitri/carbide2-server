# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# ADR-042: a project merge is the set of per-file merges where the two branch
# sets resolve differently — atomic, reconcile-or-conflict.
class ProjectMergeTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
  end

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })
  def set(data)             = d('setContents', { data: data })

  def test_merges_every_diverged_file_fast_forwarding_where_it_can
    @s.create_file('/ff',   content: "1\n")
    @s.create_file('/both', content: "a\nb\nc\n")
    @s.create_file('/same', content: "s\n")
    %w[/ff /both].each { |p| @s.branch(p, 'feature') }
    @s.write('/ff',   ins(1, 0, '2'), branch: 'feature')          # main untouched: fast-forward
    @s.write('/both', ins(0, 0, 'A'), branch: 'feature')          # both moved, disjoint: auto
    @s.write('/both', ins(2, 0, 'C'))
    @s.write('/same', ins(0, 0, 'S'))                             # no feature branch: not touched

    res = @s.merge_project(target: 'main', source: 'feature')
    assert res[:merged], res.inspect
    assert_empty res[:unresolved]
    assert_equal({ '/ff' => 'fast_forward', '/both' => 'auto' }, res[:files].to_h { |f| [f[:path], f[:action]] })
    assert_equal "1\n2", @s.read('/ff')
    assert_equal "Aa\nb\nCc\n", @s.read('/both')
    assert_equal "Ss\n", @s.read('/same')
    assert @s.state(branch_set: 'main').contains?(@s.state(branch_set: 'feature'))
  end

  def test_a_conflict_anywhere_rolls_back_everything_and_names_the_file
    @s.create_file('/clean', content: "1\n")
    @s.create_file('/dirty', content: "x\n")
    %w[/clean /dirty].each { |p| @s.branch(p, 'feature') }
    @s.write('/clean', ins(1, 0, '2'), branch: 'feature')
    @s.write('/dirty', set("theirs\n"), branch: 'feature')       # both rewrote the same line
    @s.write('/dirty', set("ours\n"))
    before_heads = %w[/clean /dirty].map { |p| head(@s, p) }
    before_seq   = @s.seq
    rev_count    = Revision.where(project_id: @s.project_id).count

    res = @s.merge_project(target: 'main', source: 'feature')
    refute res[:merged]
    assert_equal ['/dirty'], res[:unresolved].map { |u| u[:path] }
    assert_equal 'conflict', res[:unresolved].first[:reason]
    # /clean would have fast-forwarded; it did not, because the merge is atomic.
    assert_equal before_heads, %w[/clean /dirty].map { |p| head(@s, p) }
    assert_equal "1\n", @s.read('/clean')
    assert_equal "ours\n", @s.read('/dirty')
    assert_equal rev_count, Revision.where(project_id: @s.project_id).count, 'nothing committed'
    assert_equal ['/clean'], res[:files].map { |f| f[:path] }, 'what would have merged is still reported'
    assert_operator @s.seq, :>=, before_seq
  end

  def test_nothing_to_do_when_the_sets_resolve_alike
    @s.create_file('/f', content: "1\n")
    res = @s.merge_project(target: 'main', source: 'feature')
    assert res[:merged]
    assert_empty res[:files]
    assert_raises(ArgumentError) { @s.merge_project(target: 'main', source: 'main') }
  end

  def test_already_merged_files_are_skipped
    @s.create_file('/f', content: "1\n")
    @s.branch('/f', 'feature')
    @s.write('/f', ins(1, 0, '2'), branch: 'feature')
    assert @s.merge_project(target: 'main', source: 'feature')[:merged]
    again = @s.merge_project(target: 'main', source: 'feature')
    assert again[:merged]
    assert_empty again[:files], 'heads are equal after the fast-forward'
  end
end
