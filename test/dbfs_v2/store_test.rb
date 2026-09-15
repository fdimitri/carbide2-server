# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class StoreTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_create_and_read_file
    @s.create_file('/a.rb', content: "hello\nworld\n")
    assert_equal "hello\nworld\n", @s.read('/a.rb')
  end

  def test_every_keystroke_is_a_revision
    f = @s.create_file('/f.txt', content: '')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'h' }))
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'i' }))
    assert_equal 'hi', @s.read('/f.txt')
    assert_equal 2, f.revisions.count
  end

  def test_reconstruct_any_revision
    f = @s.create_file('/f.txt', content: '')
    r1 = @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'a' }))
    r2 = @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' }))
    assert_equal 'a', DbfsV2::Content.at(f, r1.first.id)
    assert_equal 'ab', DbfsV2::Content.at(f, r2.first.id)
  end

  def test_branch_and_fast_forward_merge
    @s.create_file('/f.txt', content: "line1\n")
    @s.branch('/f.txt', 'feature')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'line2' }), branch: 'feature')
    res = @s.merge('/f.txt', target: 'main', source: 'feature')
    assert res[:merged]
    assert_equal "line1\nline2", @s.read('/f.txt', branch: 'main')
  end

  def test_user_resolved_merge_creates_merge_commit
    @s.create_file('/f.txt', content: "base\n")
    @s.branch('/f.txt', 'feature')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')

    rev = @s.merge('/f.txt', target: 'main', source: 'feature', resolved: "base\nmf\n")
    assert rev.merge_commit?
    assert rev.second_parent_id.present?
    assert_equal "base\nmf\n", @s.read('/f.txt', branch: 'main')
  end

  def test_ot_concurrent_inserts_converge
    f = @s.create_file('/f.txt', content: 'X')
    base = f.branches.find_by!(name: 'main').head_revision_id
    # two clients, both based on `base`, insert at the same position
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }), base_revision_id: base, priority: 'aaa')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'B' }), base_revision_id: base, priority: 'bbb')
    assert_equal 'ABX', @s.read('/f.txt')
  end

  def test_symlink_resolves
    @s.create_file('/real.txt', content: 'target')
    @s.create_symlink('/link.txt', '/real.txt')
    assert_equal 'target', @s.read('/link.txt')
    node = @s.find('/link.txt')
    assert node.symlink?
    assert_equal '/real.txt', node.resolve.path
  end

  def test_keyframe_does_not_replace_log
    f = @s.create_file('/f.txt', content: '')
    5.times { |i| @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    @s.keyframe('/f.txt')
    assert_equal 'xxxxx', @s.read('/f.txt')
    assert_equal 5, f.revisions.count
    assert_equal 1, f.keyframes.count
  end

  def test_posix_and_owner_persisted
    @s.create_file('/f.txt', content: 'x', owner: 'alice', mode: 0o755)
    n = @s.find('/f.txt')
    assert_equal 'alice', n.owner
    assert_equal 0o755, n.posix_mode
  end
end

class BranchAndMergeCoherenceTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  # #3: create_file(branch: 'foo') must create a 'foo' branch, not rename main.
  def test_create_file_on_named_branch
    f = @s.create_file('/f.txt', content: 'hello', branch: 'feature')
    assert_equal ['feature'], f.branches.pluck(:name)
    assert_equal 'hello', @s.read('/f.txt', branch: 'feature')
    refute f.branches.exists?(name: 'main')
  end

  # #4: a fast-forward merge moves the head pointer; the document cache for the
  # target branch must be invalidated so the next write bases on the merged
  # content, not a stale buffer.
  def test_merge_invalidates_cache
    f = @s.create_file('/f.txt', content: "base\n")
    @s.read('/f.txt')                          # hydrate cache for main
    @s.branch('/f.txt', 'feature')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'x' }), branch: 'feature')
    @s.merge('/f.txt', target: 'main', source: 'feature')   # fast-forward main -> feature head
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 1, data: 'y' }))
    assert_equal "base\nxy", @s.read('/f.txt')
  end

  # Folders a create makes implicitly (root, mkdir -p parents) are attributed to
  # the creating user; folders that already existed keep their created_by.
  def test_implicit_parents_carry_the_creating_user
    @s.create_folder('/', user_id: 1)
    @s.create_file('/a/b/c.txt', content: 'x', user_id: 5)
    @s.create_file('/a/d.txt', content: 'y', user_id: 6)
    assert_equal 1, @s.find('/').created_by
    assert_equal 5, @s.find('/a').created_by
    assert_equal 5, @s.find('/a/b').created_by
    assert_equal 6, @s.find('/a/d.txt').created_by
  end

end
