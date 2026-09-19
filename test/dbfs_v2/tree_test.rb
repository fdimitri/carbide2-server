# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class TreeTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_create_sets_parent
    @s.create_file('/src/app.rb', content: 'x')
    f = @s.find('/src/app.rb')
    assert_equal '/src', f.parent.path
    assert_equal '/', @s.find('/src').parent.path
  end

  def test_root_is_auto_created
    @s.create_file('/f.txt', content: 'x')
    root = @s.find('/')
    refute_nil root
    assert_equal 'folder', root.ftype
    assert_equal '/', root.cur_name
  end

  def test_list_returns_immediate_children
    @s.create_file('/a.txt', content: '')
    @s.create_file('/b.txt', content: '')
    @s.create_folder('/sub')
    @s.create_file('/sub/c.txt', content: '')
    kids = @s.list('/').map(&:cur_name).sort
    assert_equal %w[a.txt b.txt sub], kids
    # sub has only c.txt, not a.txt/b.txt
    assert_equal ['c.txt'], @s.list('/sub').map(&:cur_name)
  end

  def test_list_is_not_prefix_leaky
    @s.create_folder('/foo')
    @s.create_file('/foo/bar.txt', content: '')
    @s.create_folder('/foobar')
    # '/foo' children must not include foobar
    assert_equal ['bar.txt'], @s.list('/foo').map(&:cur_name)
  end

  def test_tree_nested_shape
    @s.create_file('/a.txt', content: '')
    @s.create_folder('/src')
    @s.create_file('/src/app.rb', content: '')
    t = @s.tree('/')
    assert_equal '/', t[:name]
    names = t[:children].map { |c| c[:name] }.sort
    assert_equal %w[a.txt src], names
    src = t[:children].find { |c| c[:name] == 'src' }
    assert_equal ['app.rb'], src[:children].map { |c| c[:name] }
  end

  def test_move_file_preserves_history
    f = @s.create_file('/old.txt', content: 'a')
    @s.write('/old.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' }))
    rev_count = f.revisions.count
    @s.move('/old.txt', '/new.txt')
    refute @s.find('/old.txt')
    nf = @s.find('/new.txt')
    assert_equal 'ab', @s.read('/new.txt')
    assert_equal rev_count, nf.revisions.count
    assert_equal f.id, nf.id            # same file_node_id -> history intact
  end

  def test_move_directory_rewrites_descendant_paths
    @s.create_folder('/a')
    @s.create_file('/a/x.txt', content: 'x')
    @s.create_folder('/a/inner')
    @s.create_file('/a/inner/y.txt', content: 'y')
    @s.move('/a', '/b')
    refute @s.find('/a')
    assert @s.find('/b')
    assert @s.find('/b/x.txt')
    assert @s.find('/b/inner/y.txt')
    refute @s.find('/a/x.txt')
    assert_equal 'x', @s.read('/b/x.txt')
  end

  def test_move_directory_keeps_child_parent_identity
    @s.create_folder('/a')
    @s.create_file('/a/x.txt', content: 'x')
    dir = @s.find('/a')
    @s.move('/a', '/b')
    assert_equal dir.id, @s.find('/b/x.txt').parent.id
  end

  def test_rename_is_alias_for_move
    @s.create_file('/old.txt', content: 'x')
    @s.rename('/old.txt', '/renamed.txt')
    assert_equal 'x', @s.read('/renamed.txt')
  end

  def test_cannot_move_root
    @s.create_file('/f.txt', content: 'x')
    assert_raises(RuntimeError) { @s.move('/', '/elsewhere') }
  end

  def test_symlink_has_parent
    @s.create_file('/real.txt', content: 'x')
    @s.create_symlink('/link.txt', '/real.txt')
    assert_equal '/', @s.find('/link.txt').parent.path
  end
end

class MoveCycleGuardTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_move_into_self_is_rejected
    @s.create_folder('/a')
    @s.create_file('/a/x.txt', content: 'x')
    assert_raises(RuntimeError) { @s.move('/a', '/a/b') }
  end

  def test_move_into_descendant_is_rejected
    @s.create_folder('/a')
    @s.create_folder('/a/b')
    assert_raises(RuntimeError) { @s.move('/a', '/a/b/c') }
  end

  def test_move_into_existing_child_is_rejected
    @s.create_folder('/a')
    @s.create_folder('/a/x')
    assert_raises(RuntimeError) { @s.move('/a', '/a/x') }
  end

  def test_valid_move_still_works
    @s.create_folder('/a')
    @s.create_file('/a/x.txt', content: 'x')
    @s.move('/a', '/b')
    assert_equal 'x', @s.read('/b/x.txt')
  end
end

class TreeRaceRecoveryTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store

  # ensure_dir! returns the existing folder (mkdir -p). Lost-create recovery
  # is RecordNotUnique inside place!, which re-finds the winner's row.
  def test_ensure_dir_returns_existing_folder
    @s.create_folder('/a')
    node = @s.send(:ensure_dir!, '/a')
    assert_equal '/a', node.path
    assert_equal 'folder', node.ftype
  end

  def test_ensure_root_is_idempotent
    a = @s.send(:ensure_root!)
    b = @s.send(:ensure_root!)
    assert_equal a.id, b.id
    assert_equal '/', a.path
  end
end
