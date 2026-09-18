# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class ProjectGraphTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
    @s.create_file('/a.rb', content: "a\n", user_id: 1)
  end

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })

  def test_lanes_fork_and_merge_edges
    @s.create_project_branch('feature', user_id: 2)
    @s.write('/a.rb', ins(0, 0, 'F'), branch: 'feature', user_id: 2)
    @s.create_file('/f.txt', content: "f\n", branch: 'feature', user_id: 2)
    @s.create_file('/m.txt', content: "m\n", user_id: 1)          # main moves on meanwhile
    r = @s.merge_branches(source: 'feature', target: 'main', user_id: 1)
    assert r[:merged], r.inspect

    g = @s.project_graph(gap_ms: 0)
    names = g[:nodes].map { |n| n[:branch] }.uniq.sort
    assert_equal %w[feature main], names
    assert_equal %w[feature main], g[:heads].map { |h| h[:branch] }.sort
    assert_equal %w[feature main], g[:branches].map { |b| b[:name] }.sort

    # Oldest first; every edge points forward.
    index = g[:nodes].each_with_index.to_h { |n, i| [n[:id], i] }
    g[:edges].each { |e| assert index[e[:from]] < index[e[:to]], "edge #{e.inspect} goes backwards" }

    # The child's first node hangs off the parent (fork), and the merge is a
    # second-parent edge from feature into main.
    feature_first = g[:nodes].find { |n| n[:branch] == 'feature' }
    fork = g[:edges].find { |e| e[:to] == feature_first[:id] && e[:kind] == 'parent' }
    assert fork, 'fork edge'
    assert_equal 'main', g[:nodes].find { |n| n[:id] == fork[:from] }[:branch]
    assert_equal 1, feature_first[:kinds]['forked']
    merge = g[:edges].find { |e| e[:kind] == 'second_parent' }
    assert merge, 'merge edge'
    assert_equal 'feature', g[:nodes].find { |n| n[:id] == merge[:from] }[:branch]
    tgt = g[:nodes].find { |n| n[:id] == merge[:to] }
    assert_equal 'main', tgt[:branch]
    assert tgt[:kinds]['merged'], 'the target node holds the merge'

    # A node id names its branch and last seq.
    g[:nodes].each { |n| assert_match(/\A[0-9a-f-]{36}@\d+\z/, n[:id]) }
  end

  def test_gap_splits_one_authors_run
    3.times { |i| @s.write('/a.rb', ins(0, 0, i.to_s), user_id: 1) }
    one = @s.project_graph(gap_ms: 0)
    assert_equal 1, one[:nodes].count { |n| n[:branch] == 'main' && n[:kinds]['edit'] }, 'no gap: one run of edits'
    Revision.where(file_node_id: @s.find('/a.rb').id).order(:seq).last.update_columns(timestamp: Time.current + 3600)
    split = @s.project_graph(gap_ms: 1000)
    assert_operator split[:nodes].count { |n| n[:branch] == 'main' }, :>, one[:nodes].count { |n| n[:branch] == 'main' }
  end
end
