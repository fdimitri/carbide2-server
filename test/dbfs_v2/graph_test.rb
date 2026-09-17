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

end
