# frozen_string_literal: true
#
# Tombstones (soft delete).
#
# A delete must not destroy the revision DAG. Tombstoning hides the node and its
# subtree but keeps the rows, branches and revisions; re-creating the same path
# resurrects the SAME node, so history carries across a delete/re-create cycle.
require_relative 'dbfs_v2_test_helper'

class TombstoneTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  def revs(node) = Revision.where(file_node_id: node.id).count

  # --- basic delete hides but preserves -------------------------------------

  def test_delete_hides_node_but_preserves_history
    f = @s.create_file('/f', content: 'v1')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 2, data: '!' }))
    before = revs(f)
    assert_operator before, :>=, 2

    @s.delete('/f')

    assert_nil @s.find('/f'), 'tombstoned node is hidden from find'
    assert_nil @s.stat('/f')
    assert_equal before, revs(f), 'revisions must survive a delete'
    assert @s.find_any('/f').deleted?, 'the row is tombstoned, not removed'
  end

  def test_delete_removes_from_list_and_tree
    @s.create_folder('/d')
    @s.create_file('/d/a', content: 'x')
    @s.create_file('/d/b', content: 'y')

    @s.delete('/d/a')

    names = @s.list('/d').map(&:cur_name)
    assert_equal %w[b], names
    tree = @s.tree('/')
    d_node = tree[:children].find { |c| c[:path] == '/d' }
    assert_equal %w[b], d_node[:children].map { |c| c[:name] }
  end

  def test_read_of_deleted_path_is_nil
    @s.create_file('/f', content: 'hello')
    @s.delete('/f')
    assert_nil @s.read('/f'), 'a deleted file has no current content'
  end

  # --- subtree ---------------------------------------------------------------

  def test_delete_tombstones_the_whole_subtree
    @s.create_file('/d/a', content: 'x')
    @s.create_file('/d/sub/b', content: 'y')
    a = @s.find_any('/d/a')
    b = @s.find_any('/d/sub/b')

    @s.delete('/d')

    assert_nil @s.find('/d')
    assert_nil @s.find('/d/a')
    assert_nil @s.find('/d/sub/b')
    [a, b].each { |n| assert @s.find_any(n.path).deleted? }
  end

  # --- restore ---------------------------------------------------------------

  def test_restore_brings_back_node_and_subtree
    @s.create_file('/d/a', content: 'x')
    @s.delete('/d')
    assert_nil @s.find('/d/a')

    @s.restore('/d')
    assert_equal 'x', @s.read('/d/a')
  end

  # --- resurrect on re-create (history carries over) -------------------------

  def test_recreate_after_delete_resurrects_the_same_node
    f = @s.create_file('/f', content: 'old')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 3, data: '!' }))
    old_id = f.id
    old_revs = revs(f)

    @s.delete('/f')
    fresh = @s.create_file('/f', content: 'new')

    assert_equal old_id, fresh.id, 're-create must resurrect the same node (history intact)'
    refute fresh.deleted?
    assert_operator revs(fresh), :>=, old_revs, 'prior revisions are still present'
    assert_equal 'new', @s.read('/f')
    assert NilClass != @s.find('/f') # live again
  end

  def test_recreate_after_delete_preserves_branch_and_revision_access
    f = @s.create_file('/f', content: 'v1')
    first_rev = head(@s, '/f')
    @s.delete('/f')
    @s.create_file('/f', content: 'v2')
    assert_equal 'v1', @s.read('/f', revision_id: first_rev),
                 'the pre-delete revision is still reconstructable'
  end

  # --- guards ----------------------------------------------------------------

  def test_cannot_delete_root
    @s.create_file('/x', content: 'x')
    assert_raises(RuntimeError) { @s.delete('/') }
  end

  def test_delete_missing_is_nil
    assert_nil @s.delete('/nope')
  end

  def test_project_empty_reflects_live_entries_only
    @s.create_file('/f', content: 'x')
    refute @s.project_empty?
    @s.delete('/f')
    assert @s.project_empty?, 'a tombstoned-only project is empty'
  end

  # --- external delete (watcher) uses tombstone, not destroy -----------------

  def test_watcher_delete_tombstones_and_preserves_history
    root = Dir.mktmpdir
    w = DbfsV2::Watcher.new(@s, root)
    f = @s.create_file('/g', content: 'keep me')
    @s.write('/g', d('insertDataSingleLine', { startLine: 0, startChar: 7, data: '!' }))
    before = revs(f)
    DbfsV2::Flusher.new(@s, root).flush_file('/g')

    File.delete(File.join(root, 'g'))
    w.send(:handle, Struct.new(:absolute_name, :flags).new(File.join(root, 'g'), [:delete]))

    assert_nil @s.find('/g')
    assert_equal before, revs(f), 'external delete must not wipe the revision DAG'
    assert @s.find_any('/g').deleted?
  end

  # Creating under a tombstoned directory resurrects the directory (the parent
  # on the way to a create), so the path is reusable.
  def test_create_under_tombstoned_directory_resurrects_the_parent
    @s.create_file('/d/a', content: 'x')
    @s.delete('/d')
    assert_nil @s.find('/d')

    @s.create_file('/d/b', content: 'y')

    refute_nil @s.find('/d'), 'the parent directory is resurrected'
    assert_equal 'y', @s.read('/d/b')
    # the previously-deleted sibling is still tombstoned
    assert_nil @s.find('/d/a')
  end


  # --- optional listing of tombstoned nodes ---------------------------------

  def test_list_can_include_tombstoned
    @s.create_folder('/d')
    @s.create_file('/d/a', content: 'x')
    @s.create_file('/d/b', content: 'y')
    @s.delete('/d/a')

    assert_equal %w[b], @s.list('/d').map(&:cur_name)
    all = @s.list('/d', include_tombstoned: true).map(&:cur_name).sort
    assert_equal %w[a b], all
  end

  def test_tree_can_include_tombstoned_and_flags_them
    @s.create_folder('/d')
    @s.create_file('/d/a', content: 'x')
    @s.create_file('/d/b', content: 'y')
    @s.delete('/d/a')

    tree = @s.tree('/', include_tombstoned: true)
    d = tree[:children].find { |c| c[:path] == '/d' }
    by_name = d[:children].to_h { |c| [c[:name], c] }

    assert by_name['a'][:deleted], 'tombstoned child is flagged deleted: true'
    refute by_name['b'][:deleted], 'live child is not flagged'
  end

  def test_tree_can_be_rooted_at_a_tombstoned_node
    @s.create_file('/d/a', content: 'x')
    @s.delete('/d')
    assert_nil @s.tree('/d'), 'hidden by default'
    refute_nil @s.tree('/d', include_tombstoned: true)
  end

end
