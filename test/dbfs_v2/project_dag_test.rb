# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# The project DAG: every public path op appends one hashed running node;
# the running head points at live content lines; a snapshot freezes revs
# without moving HEAD.
class ProjectDagTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
  end

  def test_a_path_op_appends_one_running_node
    @s.create_file('/a/b/c.txt', content: 'x')
    head = @s.main_branch.head_node
    assert head.running?
    assert_equal %w[/a /a/b /a/b/c.txt], head.entries.order(:path).pluck(:path)
    assert_equal 1, ProjectNode.running.where(project_id: @s.project_id).count,
                 'mkdir-p + file is one public path op'
  end

  def test_the_tip_advances_on_each_path_op
    @s.create_file('/f', content: 'a')
    first = @s.main_branch.head_node_id
    @s.create_file('/g', content: 'b')
    second = @s.main_branch.head_node_id
    refute_equal first, second
    assert_equal first, @s.main_branch.head_node.parent_id
    @s.delete('/g')
    third = @s.main_branch.head_node_id
    refute_equal second, third
    assert_equal second, @s.main_branch.head_node.parent_id
    refute @s.main_branch.head_entries.exists?(path: '/g')
  end

  def test_running_entries_point_at_a_live_content_line
    @s.create_file('/f', content: "v1\n")
    e = @s.main_branch.head_entries.find_by!(path: '/f')
    refute_nil e.content_branch_id
    assert_nil e.revision_id
    cb = e.content_branch
    assert_equal 'main', cb.name
    first = cb.head_revision_id
    head_before = @s.main_branch.head_node_id
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'x' }))
    assert_equal e.content_branch_id, e.reload.content_branch_id
    refute_equal first, cb.reload.head_revision_id
    assert_equal "v1\nx", @s.read('/f')
    assert_equal head_before, @s.main_branch.reload.head_node_id,
                 'a content write does not append a project node'
  end

  def test_two_identical_trees_agree_on_the_hash
    rows = [{ file_node_id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', path: '/f', ftype: 'file',
              content_branch_id: nil, revision_id: nil }]
    a = DbfsV2::ProjectDag.tree_hash(parent_id: nil, second_parent_id: nil, kind: 'running', name: nil, entries: rows)
    b = DbfsV2::ProjectDag.tree_hash(parent_id: nil, second_parent_id: nil, kind: 'running', name: nil, entries: rows.reverse)
    assert_equal a, b
    assert_equal 64, a.size
  end

  def test_restore_walks_parents_and_puts_the_uuid_back
    n = @s.create_file('/f', content: 'old')
    @s.delete('/f')
    assert @s.find_any('/f').deleted?
    assert_equal n.id, @s.find_any('/f').id
    @s.restore('/f')
    assert_equal n.id, @s.find('/f').id
    assert_equal 'old', @s.read('/f')
  end

  def test_recreate_resurrects_the_same_identity
    n = @s.create_file('/f', content: 'old')
    @s.delete('/f')
    again = @s.create_file('/f', content: 'new')
    assert_equal n.id, again.id
    assert_equal 'new', @s.read('/f')
  end

  def test_fork_node_is_a_frozen_cut
    @s.create_file('/f', content: "a\n")
    pb = @s.create_project_branch('feature')
    cut = ProjectNode.find(pb.fork_node_id)
    assert cut.snapshot?
    @s.write('/f', d('setContents', { data: "main\n" }))
    frozen = cut.entries.find_by!(path: '/f')
    assert_equal "a\n", DbfsV2::Content.at(FileNode.find(frozen.file_node_id), frozen.revision_id)
    assert_equal "a\n", @s.read('/f', branch: 'feature')
  end
end
