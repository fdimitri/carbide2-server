# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# The project clock, FileEvents as notifications, and Store#state.
# state(branch:, seq:) is this branch at clock S (path-op node + reflog).
# Omit seq: for the running head. Not a BranchSet fold.
class ProjectStateTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
  end

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })

  def test_every_revision_takes_the_next_seq_in_commit_order
    @s.create_file('/f', content: 'a')
    before = @s.seq
    3.times { |i| @s.write('/f', ins(0, 1 + i, 'b')) }
    seqs = Revision.where(file_node_id: @s.find('/f').id).order(:seq).pluck(:seq)
    assert_equal seqs.sort, seqs
    assert_equal seqs.uniq, seqs, 'no two revisions share a seq'
    assert seqs.all?(&:positive?)
    assert_equal before + 3, @s.seq
    assert_equal @s.project_id, Revision.find(head(@s, '/f')).project_id
  end

  def test_the_clock_is_per_project
    other = setup_store
    @s.create_file('/f', content: 'a')
    other.create_file('/g', content: 'b')
    assert_equal @s.seq, other.seq, 'two fresh projects tick independently to the same value'
    @s.write('/f', ins(0, 1, 'x'))
    assert_equal other.seq + 1, @s.seq
  end

  def test_create_delete_restore_and_move_are_events_and_one_operation_is_one_seq
    @s.create_file('/dir/a.rb', content: 'a')
    @s.create_file('/dir/sub/b.rb', content: 'b')
    ev = ->(kind) { FileEvent.where(project_id: @s.project_id, kind: kind).order(:seq, :path) }

    assert_equal %w[/dir /dir/a.rb /dir/sub /dir/sub/b.rb], ev.call('created').pluck(:path)

    @s.move('/dir', '/moved')
    renamed = ev.call('renamed')
    assert_equal %w[/moved /moved/a.rb /moved/sub /moved/sub/b.rb], renamed.pluck(:path)
    assert_equal %w[/dir /dir/a.rb /dir/sub /dir/sub/b.rb], renamed.pluck(:from_path)
    assert_equal 1, renamed.pluck(:seq).uniq.size, 'a folder move is one operation'

    @s.delete('/moved')
    deleted = ev.call('deleted')
    assert_equal 4, deleted.count
    assert_equal 1, deleted.pluck(:seq).uniq.size, 'a subtree delete is one operation'
    first_delete = deleted.maximum(:seq)

    @s.restore('/moved')
    assert_equal 4, ev.call('restored').count

    @s.delete('/moved/sub')
    @s.delete('/moved')
    last_op = ev.call('deleted').where('seq > ?', first_delete).maximum(:seq)
    assert_equal %w[/moved /moved/a.rb], ev.call('deleted').where(seq: last_op).pluck(:path).sort
  end

  def test_recreating_over_a_tombstone_is_a_created_event_on_the_same_node
    n = @s.create_file('/f', content: 'a')
    @s.delete('/f')
    again = @s.create_file('/f', content: 'b')
    assert_equal n.id, again.id
    assert_equal %w[created deleted created], FileEvent.where(file_node_id: n.id).order(:seq).pluck(:kind)
  end

  def test_state_is_the_running_head
    @s.create_file('/a', content: "A\n")
    @s.create_file('/b', content: "B\n")
    @s.write('/a', ins(1, 0, 'more'))
    @s.delete('/b')
    @s.move('/a', '/c')

    now = @s.state
    assert_equal ['/c'], now.paths
    assert_equal "A\nmore", now.read('/c')
    assert_equal @s.find('/c').id, now['/c'].file_node_id
  end

  def test_a_deleted_folder_hides_its_subtree_and_empty_folders_carry_existence
    @s.create_folder('/empty')
    @s.create_file('/dir/f', content: 'x')
    st = @s.state
    assert_equal ['/dir', '/dir/f', '/empty'], st.paths
    assert st['/empty'].folder?
    assert_nil st.read('/empty')
    @s.delete('/dir')
    assert_equal ['/empty'], @s.state.paths
  end

  def test_fast_forward_moves_the_live_head
    @s.create_file('/f', content: "1\n")
    @s.branch('/f', 'feature')
    @s.write('/f', ins(1, 0, '2'), branch: 'feature')
    feat = head(@s, '/f', 'feature')
    before = @s.seq
    res = @s.merge('/f', target: 'main', source: 'feature')
    assert res[:merged]
    now = @s.state
    assert_equal feat, now['/f'].revision_id, "main's head at now is the source head, though no revision was created"
    assert_equal "1\n2", now.read('/f')
    assert_equal before + 1, @s.seq, 'a fast-forward is a move of its own and ticks'
  end

  def test_deleting_a_branch_frees_the_name
    @s.create_file('/f', content: "a\n")
    @s.branch('/f', 'feat')
    @s.write('/f', ins(1, 0, 'b'), branch: 'feat')
    feat_head = head(@s, '/f', 'feat')
    @s.write('/f', ins(0, 0, 'M'))

    @s.delete_branch('/f', 'feat')
    assert_equal %w[main], @s.branches('/f').map { |b| b[:name] }
    assert Branch.tombstoned.exists?(file_node_id: @s.find('/f').id, name: 'feat')
    assert Revision.exists?(id: feat_head)
    assert_equal 'feat', Revision.find(feat_head).branch.name, 'the revision still knows which branch it was committed on'

    condensed = @s.dag_condensed('/f')
    assert_equal ['main'], condensed[:heads].map { |h| h[:branch] }
    assert_includes condensed[:nodes].map { |n| n[:branch] }, 'feat'

    again = @s.branch('/f', 'feat')
    refute again.deleted?
    assert_equal %w[feat main], @s.branches('/f').map { |b| b[:name] }
    labels = @s.dag('/f')
    assert_equal ['main', 'feat'].sort, labels[:heads].map { |h| h[:branch] }.sort
  end

  def test_diff_is_keyed_by_identity
    @s.create_file('/a', content: "a\n")
    @s.create_file('/b', content: "b\n")
    from = @s.state
    @s.move('/a', '/renamed')
    @s.write('/b', ins(0, 0, 'B'))
    @s.create_file('/c', content: 'c')
    @s.delete('/b')
    to = @s.state

    diff = from.diff(to)
    assert_equal ['/c'], diff[:added].map(&:path)
    assert_equal ['/b'], diff[:removed].map(&:path)
    assert_equal [{ from: '/a', to: '/renamed' }], diff[:renamed].map { |r| r.slice(:from, :to) }
    assert_empty diff[:modified], 'the renamed file has the same revision; the modified one was removed'
  end

  def test_snapshot_freezes_identity_revs_and_does_not_move_head
    @s.create_file('/a', content: "v1\n")
    head_before = @s.main_branch.head_node_id
    snap = @s.snapshot!('v1', user_id: 7)
    assert_equal head_before, @s.main_branch.reload.head_node_id, 'HEAD stays on the running node'
    assert_equal head_before, snap.parent_id
    assert snap.snapshot?

    @s.write('/a', ins(0, 0, 'changed '))
    @s.create_file('/b', content: 'b')

    assert_equal 'v1', @s.snapshot('v1').name
    assert_equal 7, snap.user_id
    frozen = snap.entries.find_by!(path: '/a')
    assert_equal "v1\n", DbfsV2::Content.at(FileNode.find(frozen.file_node_id), frozen.revision_id)
    refute snap.entries.exists?(path: '/b')
    assert @s.main_branch.head_entries.exists?(path: '/b')
    assert_raises(ActiveRecord::RecordInvalid) { @s.snapshot!('v1') }
    assert_equal ['v1'], @s.snapshots.where.not(name: nil).map(&:name)
  end

  def test_a_path_op_node_and_its_events_share_one_seq
    @s.create_file('/a/b/c.txt', content: 'x')
    node = @s.main_branch.head_node
    ev = FileEvent.where(project_id: @s.project_id, kind: 'created').order(:path)
    assert_equal %w[/a /a/b /a/b/c.txt], ev.pluck(:path)
    assert_equal [node.seq], ev.pluck(:seq).uniq
    assert_equal node.seq, @s.seq, 'the path op is the last tick; events did not tick again'

    @s.move('/a/b/c.txt', '/other/c.txt')
    moved = @s.main_branch.head_node
    created = FileEvent.where(project_id: @s.project_id, kind: 'created', path: '/other')
    renamed = FileEvent.where(project_id: @s.project_id, kind: 'renamed')
    assert_equal moved.seq, created.pick(:seq)
    assert_equal [moved.seq], renamed.pluck(:seq).uniq
    refute_equal node.seq, moved.seq
  end

  def test_content_writes_do_not_stamp_a_new_project_seq
    @s.create_file('/f', content: "v1\n")
    node = @s.main_branch.head_node
    seq = node.seq
    @s.write('/f', ins(1, 0, 'x'))
    assert_equal node.id, @s.main_branch.reload.head_node_id
    assert_equal seq, @s.main_branch.head_node.seq
    assert_operator @s.seq, :>, seq
  end

  def test_state_at_seq_is_the_tree_and_content_at_that_cut
    @s.create_file('/a', content: "A\n")
    s_create = @s.main_branch.head_node.seq
    id_a = @s.find('/a').id
    @s.write('/a', ins(1, 0, 'more'))
    s_write = @s.seq
    @s.create_file('/b', content: "B\n")
    s_b = @s.main_branch.head_node.seq
    @s.delete('/a')

    early = @s.state(seq: s_create)
    assert_equal ['/a'], early.paths
    assert_equal "A\n", early.read('/a')
    assert_equal id_a, early['/a'].file_node_id

    mid = @s.state(seq: s_write)
    assert_equal ['/a'], mid.paths
    assert_equal "A\nmore", mid.read('/a')

    later = @s.state(seq: s_b)
    assert_equal ['/a', '/b'], later.paths
    assert_equal "A\nmore", later.read('/a')
    assert_equal "B\n", later.read('/b')

    assert_equal ['/b'], @s.state.paths
    assert_empty @s.state(seq: 0).paths
  end

  def test_state_at_seq_on_a_project_branch_does_not_follow_later_edits
    @s.create_file('/f', content: "main\n")
    pb = @s.create_project_branch('feature')
    fork_seq = pb.head_node.seq
    @s.write('/f', ins(0, 0, 'feat '), branch: 'feature')
    @s.write('/f', ins(0, 0, 'MAIN '))
    @s.create_file('/only-main', content: 'x')

    cut = @s.state(branch: 'feature', seq: fork_seq)
    assert_equal ['/f'], cut.paths
    assert_equal "main\n", cut.read('/f')

    live = @s.state(branch: 'feature')
    assert_equal ['/f'], live.paths
    assert_equal "feat main\n", live.read('/f')
    assert @s.state.include?('/only-main')
    refute live.include?('/only-main')
    assert_empty @s.state(branch: 'feature', seq: pb.seq - 1).paths
  end

  def test_identity_axis_is_running_nodes_and_named_snapshot_marks
    @s.create_file('/a', content: 'a')
    first = @s.main_branch.head_node
    @s.write('/a', ins(0, 0, 'x'))
    @s.create_file('/b', content: 'b')
    second = @s.main_branch.head_node
    @s.snapshot!('cut')
    axis = @s.identity_axis
    assert_equal 'main', axis[:branch]
    assert_equal [first.seq, second.seq], axis[:ticks].map { |t| t[:seq] }
    assert_equal [first.id, second.id], axis[:ticks].map { |t| t[:node_id] }
    assert_equal ['cut'], axis[:marks].map { |m| m[:name] }
    refute_includes axis[:ticks].map { |t| t[:node_id] }, axis[:marks].first[:node_id]
  end

  def test_identity_at_is_the_tree_and_events_at_that_seq
    n = @s.create_file('/dir/f.txt', content: 'x')
    seq = @s.main_branch.head_node.seq
    at = @s.identity_at(seq: seq)
    assert_equal seq, at[:seq]
    assert_equal @s.main_branch.head_node_id, at[:node][:id]
    assert_equal %w[/dir /dir/f.txt], at[:entries].map { |e| e[:path] }
    assert_equal n.id, at[:entries].find { |e| e[:path] == '/dir/f.txt' }[:id]
    assert_equal %w[created created], at[:events].map { |e| e[:kind] }
    assert_equal [seq], at[:events].map { |e| FileEvent.find_by!(file_node_id: e[:file_node_id], seq: seq).seq }.uniq

    @s.write('/dir/f.txt', ins(0, 0, 'y'))
    mid = @s.identity_at(seq: @s.seq)
    assert_equal %w[/dir /dir/f.txt], mid[:entries].map { |e| e[:path] }
    assert_empty mid[:events], 'a content write is not a path-op tick'

    @s.move('/dir/f.txt', '/renamed.txt')
    moved = @s.identity_at(seq: @s.main_branch.head_node.seq)
    assert_equal n.id, moved[:entries].find { |e| e[:path] == '/renamed.txt' }[:id]
    refute moved[:entries].any? { |e| e[:path] == '/dir/f.txt' }
    assert_equal ['renamed'], moved[:events].map { |e| e[:kind] }.uniq
    assert_equal '/dir/f.txt', moved[:events].find { |e| e[:file_node_id] == n.id }[:from_path]
  end

  def test_identity_axis_on_a_fork_is_that_branch_only
    @s.create_file('/f', content: 'a')
    @s.create_project_branch('feature')
    @s.create_file('/g', content: 'b', branch: 'feature')
    main = @s.identity_axis
    feat = @s.identity_axis(branch: 'feature')
    refute_equal main[:ticks].map { |t| t[:node_id] }, feat[:ticks].map { |t| t[:node_id] }
    assert feat[:ticks].size >= 1
    g = @s.identity_at(seq: feat[:ticks].last[:seq], branch: 'feature')
    assert g[:entries].any? { |e| e[:path] == '/g' }
    refute @s.identity_at(seq: main[:ticks].last[:seq])[:entries].any? { |e| e[:path] == '/g' }
  end
end
