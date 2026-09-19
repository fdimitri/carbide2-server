# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# Project branches (ADR-042, step 2): a branch of the whole tree with its own
# existence log and path index, content frozen at the fork until written.
class ProjectBranchTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
    @s.create_folder('/lib')
    @s.create_file('/lib/a.rb', content: "a1\n")
    @s.create_file('/lib/b.rb', content: "b1\n")
    @s.create_file('/README', content: "readme\n")
  end

  def set(data) = d('setContents', { data: data })
  def paths(tree) = flat(tree).sort
  def flat(n) = [n[:path]] + (n[:children] || []).flat_map { |c| flat(c) }
  def state_paths(branch) = @s.state(branch: branch).paths

  def test_fork_copies_the_index_and_content_reads_through
    pb = @s.create_project_branch('feature')
    refute pb.main?
    assert_equal @s.main_branch.id, pb.forked_from_id
    assert_equal pb.seq, pb.fork_seq
    assert_equal paths(@s.tree('/')), paths(@s.tree('/', branch: 'feature'))
    assert_equal "a1\n", @s.read('/lib/a.rb', branch: 'feature')
    assert_equal %w[main feature], @s.project_branches.map(&:name)
    # The fold of the branch's lineage agrees with its index.
    assert_equal paths(@s.tree('/', branch: 'feature')) - ['/'], state_paths('feature')
  end

  def test_a_branch_is_frozen_at_the_fork_not_an_overlay
    @s.create_project_branch('feature')
    @s.write('/lib/a.rb', set("a2 on main\n"))
    @s.create_file('/lib/c.rb', content: "c on main\n")
    assert_equal "a1\n", @s.read('/lib/a.rb', branch: 'feature')
    assert_nil @s.find('/lib/c.rb', branch: 'feature')
    st = @s.state(branch: 'feature')
    assert_equal head_at_fork = @s.find('/lib/a.rb').branches.find_by!(name: 'main').branch_heads.order(:seq).first.revision_id,
                 st['/lib/a.rb'].revision_id
    assert_equal "a1\n", st.read('/lib/a.rb')
  end

  def test_first_write_forks_a_content_branch_bound_to_the_project_branch
    pb = @s.create_project_branch('feature')
    @s.write('/lib/a.rb', set("a2 on feature\n"), branch: 'feature')
    assert_equal "a2 on feature\n", @s.read('/lib/a.rb', branch: 'feature')
    assert_equal "a1\n", @s.read('/lib/a.rb')
    cb = @s.find('/lib/a.rb').branches.find_by!(name: 'feature')
    assert_equal pb.id, cb.project_branch_id
    assert_equal head(@s, '/lib/a.rb'), cb.origin_revision_id
    assert_equal cb.head_revision_id, @s.state(branch: 'feature')['/lib/a.rb'].revision_id
    assert_nil @s.find('/lib/b.rb').branches.find_by(name: 'feature'), 'untouched files stay pinned, no row'
  end

  def test_a_file_created_on_a_branch_is_not_on_main
    @s.create_project_branch('feature')
    node = @s.create_file('/lib/only.rb', content: "only\n", branch: 'feature')
    assert_equal '/lib/only.rb', node.path
    assert_nil @s.find('/lib/only.rb')
    assert FileNode.find(node.id).deleted?, 'tombstoned on main'
    assert FileNode.find(node.id).path.start_with?(DbfsV2::BranchFs::PLACEHOLDER)
    assert_equal "only\n", @s.read('/lib/only.rb', branch: 'feature')
    assert_includes state_paths('feature'), '/lib/only.rb'
    refute_includes @s.state.paths, '/lib/only.rb'
    ev = FileEvent.where(file_node_id: node.id).order(:seq).to_a
    assert_equal %w[created], ev.map(&:kind)
    assert_equal @s.project_branch('feature').id, ev.first.project_branch_id
  end

  def test_rename_delete_restore_on_a_branch_leave_main_alone_and_fold
    @s.create_project_branch('feature')
    @s.move('/lib/a.rb', '/lib/renamed.rb', branch: 'feature')
    @s.delete('/README', branch: 'feature')
    @s.create_folder('/deep/er', branch: 'feature')
    assert_equal ['/', '/README', '/lib', '/lib/a.rb', '/lib/b.rb'], paths(@s.tree('/'))
    assert_equal ['/', '/deep', '/deep/er', '/lib', '/lib/b.rb', '/lib/renamed.rb'], paths(@s.tree('/', branch: 'feature'))
    assert_equal "a1\n", @s.read('/lib/renamed.rb', branch: 'feature')
    assert_equal paths(@s.tree('/', branch: 'feature')) - ['/'], state_paths('feature')

    @s.restore('/README', branch: 'feature')
    assert_equal "readme\n", @s.read('/README', branch: 'feature')
    assert_equal paths(@s.tree('/', branch: 'feature')) - ['/'], state_paths('feature')
    # Same identity across the rename, so history is the file's.
    id = @s.find('/lib/a.rb').id
    assert_equal id, @s.find('/lib/renamed.rb', branch: 'feature').id
    found = @s.find_id(id, branch: 'feature')
    assert_equal '/lib/renamed.rb', found.path
    assert_equal id, found.id
    assert_equal 3, FileEvent.where(project_branch_id: @s.project_branch('feature').id, kind: %w[renamed deleted restored]).count
  end

  def test_list_and_stat_on_a_branch
    @s.create_project_branch('feature')
    @s.create_file('/lib/z.rb', branch: 'feature')
    assert_equal %w[a.rb b.rb z.rb], @s.list('/lib', branch: 'feature').map(&:cur_name)
    assert_equal %w[a.rb b.rb], @s.list('/lib').map(&:cur_name)
    st = @s.stat('/lib/z.rb', branch: 'feature')
    assert_equal ['/lib/z.rb', 'file'], [st[:path], st[:type]]
  end

  def test_a_past_state_of_a_branch_folds_by_seq
    @s.create_project_branch('feature')
    before = @s.seq
    @s.create_file('/later.rb', content: "x\n", branch: 'feature')
    refute_includes @s.state(seq: before, branch: 'feature').paths, '/later.rb'
    assert_includes @s.state(branch: 'feature').paths, '/later.rb'
  end

  def test_delete_frees_the_name_without_reviving_the_old_branch
    old = @s.create_project_branch('feature')
    @s.write('/lib/a.rb', set("old feature\n"), branch: 'feature')
    cut = @s.seq
    @s.delete_project_branch('feature')
    assert @s.project_branch('feature').nil?
    assert ProjectBranch.find(old.id).deleted?
    fresh = @s.create_project_branch('feature')
    refute_equal old.id, fresh.id
    assert_equal "a1\n", @s.read('/lib/a.rb', branch: 'feature'), 'new row, forked from main now'
    # The old branch's state at its cut still folds from its own rows.
    assert_equal "old feature\n", DbfsV2::ProjectState.at(@s, seq: cut, branch: old).read('/lib/a.rb')
    assert_raises(ArgumentError) { @s.delete_project_branch('main') }
  end

  def test_a_detached_per_file_branch_of_the_same_name_is_adopted
    @s.branch('/lib/b.rb', 'feature')
    @s.write('/lib/b.rb', set("per-file feature\n"), branch: 'feature')
    pb = @s.create_project_branch('feature')
    assert_equal "b1\n", @s.read('/lib/b.rb', branch: 'feature'), 'pinned at fork until written'
    @s.write('/lib/b.rb', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: '>' }), branch: 'feature')
    cb = @s.find('/lib/b.rb').branches.find_by!(name: 'feature')
    assert_equal pb.id, cb.project_branch_id
    assert_equal ">per-file feature\n", @s.read('/lib/b.rb', branch: 'feature')
  end

  def test_nested_forks_fold_through_the_lineage
    @s.create_project_branch('feature')
    @s.write('/lib/a.rb', set("feature a\n"), branch: 'feature')
    @s.create_file('/f.txt', content: "f\n", branch: 'feature')
    sub = @s.create_project_branch('sub', from: 'feature')
    assert_equal @s.project_branch('feature').id, sub.forked_from_id
    assert_equal "feature a\n", @s.read('/lib/a.rb', branch: 'sub')
    assert_equal "f\n", @s.read('/f.txt', branch: 'sub')
    @s.write('/lib/a.rb', set("feature a2\n"), branch: 'feature')
    @s.delete('/f.txt', branch: 'feature')
    assert_equal "feature a\n", @s.read('/lib/a.rb', branch: 'sub')
    st = @s.state(branch: 'sub')
    assert_includes st.paths, '/f.txt'
    assert_equal "feature a\n", st.read('/lib/a.rb')
    assert_equal paths(@s.tree('/', branch: 'sub')) - ['/'], st.paths
  end

  def test_per_file_merge_of_a_project_branch_into_main
    @s.create_project_branch('feature')
    @s.write('/lib/a.rb', set("feature a\n"), branch: 'feature')
    res = @s.merge('/lib/a.rb', target: 'main', source: 'feature', auto: true)
    assert res[:merged], res.inspect
    assert_equal "feature a\n", @s.read('/lib/a.rb')
    pv = @s.merge_preview('/lib/b.rb', target: 'main', source: 'feature', branch: 'feature')
    assert pv[:clean], 'untouched on feature: its content row is created at the pin, nothing to merge'
  end
end
