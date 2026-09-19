# frozen_string_literal: true
#
# Path safety.
#
# DBFS paths are virtual and rooted. Traversal segments must not let a flush
# escape the root, a file must not contain children, and a file created on a
# non-main branch must still answer stat/read.
require_relative 'dbfs_v2_test_helper'
require 'tmpdir'

class PathSafetyTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  # normalize() rejects '.'/'..' segments, and Flusher#disk_path verifies the
  # joined path stays inside the root.
  def test_dotdot_paths_cannot_escape_the_flush_root
    root = Dir.mktmpdir
    begin
      @s.create_file('/a/../../escape.txt', content: 'x')
      DbfsV2::Flusher.new(@s, root).flush_file('/a/../../escape.txt')
    rescue StandardError
      nil # rejecting the path is an acceptable outcome
    end
    refute File.exist?(File.expand_path('../escape.txt', root)), 'flush wrote outside the root'
  end

  # A file is a leaf: it cannot be used as a parent directory.
  def test_cannot_create_a_file_under_a_file
    @s.create_file('/a', content: 'x')
    assert_raises(StandardError) { @s.create_file('/a/b', content: 'y') }
  end

  # A file created on a non-main branch has no 'main' branch row; stat (and the
  # default-branch read) must still answer rather than raising RecordNotFound.
  def test_stat_on_file_without_main_branch
    @s.create_file('/f', content: 'x', branch: 'foo')
    assert_equal 'x', @s.read('/f', branch: 'foo')
    refute_nil @s.stat('/f')
  end

  # --- normalize ------------------------------------------------------------

  def norm(p) = @s.send(:normalize, p)

  def test_normalize_canonicalizes_paths
    assert_equal '/a/b', norm('/a//b')     # collapsed slashes
    assert_equal '/a/b', norm('/a/b/')     # trailing slash
    assert_equal '/a/b', norm('/a/b///')   # many trailing slashes
    assert_equal '/a/b', norm('a/b')       # relative -> rooted
    assert_equal '/',    norm('/')
    assert_equal '/',    norm('//')
    assert_equal '/',    norm('')          # empty -> root
  end

  def test_normalize_rejects_dot_and_dotdot_segments
    assert_raises(ArgumentError) { norm('/a/./b') }
    assert_raises(ArgumentError) { norm('/a/../b') }
    assert_raises(ArgumentError) { norm('..') }
  end

  # --- duplicate create -----------------------------------------------------

  # Duplicate create is refused without clobbering. BranchFs raises a
  # destination error (the unique live-path index is the backstop).
  def test_create_file_on_existing_path_raises_and_does_not_overwrite
    @s.create_file('/f', content: 'x')
    err = assert_raises(RuntimeError) { @s.create_file('/f', content: 'y') }
    assert_match(/destination already exists/, err.message)
    assert_equal 'x', @s.read('/f'), 'the existing file must be untouched'
  end

  def test_create_folder_colliding_with_existing_node_raises
    @s.create_folder('/d')
    assert_raises(RuntimeError) { @s.create_folder('/d') }
    @s.create_file('/g', content: 'x')
    assert_raises(RuntimeError) { @s.create_folder('/g') } # folder where file is
  end

end
