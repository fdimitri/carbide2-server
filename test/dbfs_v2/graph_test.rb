# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class GraphTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_dump_lists_branches
    @s.create_file('/f', content: "a\n")
    @s.branch('/f', 'feature')
    g = @s.dag('/f')
    assert_equal %w[feature main], g[:branches].keys.sort
    assert_equal 2, g[:heads].length
  end

  def test_dump_linear_chain_has_n_minus_one_edges
    @s.create_file('/f', content: '')
    3.times { |i| @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    g = @s.dag('/f')
    assert_equal 3, g[:nodes].length
    assert_equal 2, g[:edges].length
    assert g[:edges].all? { |e| e[:kind] == 'parent' }
  end

  def test_merge_commit_adds_second_parent_edge
    @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    @s.merge('/f', target: 'main', source: 'feature', resolved: "x\nmf\n")

    g = @s.dag('/f')
    assert g[:edges].any? { |e| e[:kind] == 'second_parent' }
    # main's head is the merge commit, and it has two parents
    main_head = g[:branches]['main']
    merge_node = g[:nodes].find { |n| n[:id] == main_head }
    assert merge_node[:second_parent]
  end

  def test_dot_export_is_valid
    @s.create_file('/f', content: 'x')
    dot = @s.dag_dot('/f')
    assert dot.start_with?('digraph dbfs {')
    assert dot.end_with?('}')
    assert_includes dot, '->'
  end

  def test_dag_errors_on_unknown_path
    assert_raises(RuntimeError) { @s.dag('/nope') }
  end

  # --- merge commit contract (the DAG the graph UI renders) ------------------

  def test_merge_commit_dag_and_dot_contract
    @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }))
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    # The second parent is the source head at MERGE time (after feature's write).
    feat_head = @s.find('/f').branches.find_by!(name: 'feature').head_revision_id
    @s.merge('/f', target: 'main', source: 'feature', resolved: "x\nmf\n")

    g = @s.dag('/f')
    main_head = g[:branches]['main']

    # Exactly one second-parent edge, from the source's pre-merge head to the
    # merge commit.
    sp = g[:edges].select { |e| e[:kind] == 'second_parent' }
    assert_equal 1, sp.size, 'merge commit must add exactly one second-parent edge'
    assert_equal main_head, sp.first[:to], 'second-parent edge must point at the merge commit'
    assert_equal feat_head, sp.first[:from], 'second-parent edge must come from the source head'

    # Every edge references a node that is present (the UI walks these blindly).
    ids = g[:nodes].map { |n| n[:id] }
    g[:edges].each do |e|
      assert_includes ids, e[:from]
      assert_includes ids, e[:to]
    end

    # The merge node itself carries the second parent.
    merge_node = g[:nodes].find { |n| n[:id] == main_head }
    assert_equal feat_head, merge_node[:second_parent]

    # DOT: the second parent is dashed, exactly once, and both heads are boxes.
    dot = @s.dag_dot('/f')
    assert_equal 1, dot.scan('style=dashed').size, 'exactly the second-parent edge is dashed'
    assert_includes dot, 'head_main'
    assert_includes dot, 'head_feature'
    assert dot.start_with?('digraph dbfs {')
    assert dot.rstrip.end_with?('}')
  end

  # --- condensed DAG (what the history rail renders) -------------------------

  def ins(line, char, data) = DbfsV2::Delta.new('insertDataSingleLine', { startLine: line, startChar: char, data: data })
  def head_of(name) = @s.find('/f').branches.find_by!(name: name).head_revision_id

  def test_condense_collapses_linear_typing_and_splits_on_user_and_gap
    @s.create_file('/f', content: '', user_id: 1)
    5.times { |i| @s.write('/f', ins(0, i, 'a'), user_id: 1) }
    3.times { |i| @s.write('/f', ins(0, 5 + i, 'b'), user_id: 2) }
    # A pause: push the next revisions' timestamps 10 s out.
    late = Revision.where(file_node_id: @s.find('/f').id).order(:timestamp).last.timestamp + 10
    2.times { |i| @s.write('/f', ins(0, 8 + i, 'c'), user_id: 2) }
    Revision.where(file_node_id: @s.find('/f').id).order(:timestamp).last(2).each_with_index do |r, i|
      r.update_columns(timestamp: late + i)
    end

    g = @s.dag_condensed('/f')
    # An empty create writes no revision: user 1's 5 keystrokes = one run;
    # user 2's 5 = one run (no gap set).
    assert_equal [5, 5], g[:nodes].map { |n| n[:count] }
    assert_equal [1, 2], g[:nodes].map { |n| n[:user_id] }
    assert_equal head_of('main'), g[:nodes].last[:id], 'a node is named by its last revision'
    assert_equal 1, g[:edges].size
    assert_equal({ 'insertDataSingleLine' => 5 }, g[:nodes].last[:kinds])
    assert_equal [{ branch: 'main', revision: head_of('main') }], g[:heads]

    g = @s.dag_condensed('/f', gap_ms: 3000)
    assert_equal [5, 3, 2], g[:nodes].map { |n| n[:count] }, 'the 10 s pause splits user 2'
    assert_equal 3000, g[:gap_ms]
  end

  def test_condense_keeps_forks_heads_and_merges_as_nodes
    @s.create_file('/f', content: "x\n", user_id: 1)
    @s.write('/f', ins(0, 1, 'y'), user_id: 1)
    @s.branch('/f', 'feature')                                 # fork at main's head
    fork = head_of('main')
    @s.write('/f', ins(1, 0, 'm'), user_id: 1)                 # main continues
    @s.write('/f', ins(1, 0, 'f'), user_id: 1, branch: 'feature')
    @s.write('/f', ins(1, 1, 'g'), user_id: 1, branch: 'feature')
    feat = head_of('feature')
    @s.merge('/f', target: 'main', source: 'feature', resolved: "xy\nmfg\n", user_id: 1)

    g = @s.dag_condensed('/f')
    by_id = g[:nodes].to_h { |n| [n[:id], n] }
    # The fork point ends a run even though everything is one user on main.
    assert by_id.key?(fork), 'the fork revision is a node'
    assert_equal 2, by_id[fork][:count]
    assert_equal 'feature', by_id[feat][:branch]
    assert_equal 2, by_id[feat][:count]
    assert_equal 'main', by_id[head_of('main')][:branch]
    assert_equal 2, by_id[head_of('main')][:count], "main's 'm' and the merge commit: the commit ends the run"
    assert_equal head_of('main'), by_id[head_of('main')][:id]
    assert_equal %w[feature main], g[:heads].map { |h| h[:branch] }
    sp = g[:edges].select { |e| e[:kind] == 'second_parent' }
    assert_equal [{ from: feat, to: head_of('main'), kind: 'second_parent' }], sp
    # Every edge names nodes that are present; parents come before children.
    pos = g[:nodes].each_with_index.to_h { |n, i| [n[:id], i] }
    g[:edges].each { |e| assert pos[e[:from]] < pos[e[:to]], "#{e.inspect} out of order" }
  end

  def test_condense_folds_auto_branches_unless_asked
    @s.create_file('/f', content: "one\ntwo\n", user_id: 1)
    base = head_of('main')
    @s.write('/f', ins(0, 0, 'X'), user_id: 2)                 # someone else on main
    r = ProjectFs.write_batch!(@s, '/f', [ins(1, 3, '!'), ins(1, 4, '?')], base_revision_id: base, user_id: 1)
    assert_equal :rebased, r.mode

    g = @s.dag_condensed('/f')
    assert_equal %w[main], g[:heads].map { |h| h[:branch] }, 'the auto-branch is folded'
    refute g[:nodes].any? { |n| n[:branch].start_with?('auto/') }
    rebased = g[:nodes].find { |n| n[:id] == r.head }
    assert_equal 2, rebased[:count], 'the two rebased edits are one run'
    assert_equal({ branch: r.branch, count: 2 }, rebased[:rebased])
    assert_empty g[:edges].select { |e| e[:kind] == 'second_parent' }

    g = @s.dag_condensed('/f', auto: true)
    assert_equal ['main', r.branch].sort, g[:heads].map { |h| h[:branch] }.sort
    auto_node = g[:nodes].find { |n| n[:id] == r.branch_head }
    assert_equal 2, auto_node[:count]
    assert_equal r.branch, auto_node[:branch]
    assert_nil g[:nodes].find { |n| n[:id] == r.head }[:rebased]
    assert_equal [{ from: r.branch_head, to: r.head, kind: 'second_parent' }],
                 g[:edges].select { |e| e[:kind] == 'second_parent' }
    # The fork at `base` is now visible: base ends a run.
    assert g[:nodes].any? { |n| n[:id] == base }
  end
end
