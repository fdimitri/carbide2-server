# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class KeyframeTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_duplicate_keyframe_is_idempotent
    f = @s.create_file('/f', content: 'abc')
    @s.keyframe('/f')
    @s.keyframe('/f')   # must not raise on unique index
    assert_equal 1, f.keyframes.count
  end

  def test_cold_read_from_mid_chain_keyframe
    f = @s.create_file('/f', content: '')
    5.times { |i| @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    @s.keyframe('/f')                          # keyframe at rev 5
    3.times { |i| @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 5 + i, data: 'y' })) }
    DbfsV2::DocumentCache.invalidate_node(f.id)  # force cold replay
    assert_equal 'xxxxxyyy', @s.read('/f')
  end

  def test_read_revision_before_keyframe
    f = @s.create_file('/f', content: '')
    revs = 6.times.map { |i| @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })).first }
    @s.keyframe('/f')
    # read a revision that predates the keyframe (the 3rd insert)
    assert_equal 'xxx', DbfsV2::Content.at(f, revs[2].id)
  end
end

class MergeAncestryTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_new_since_across_merge_commit
    f = @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    main_head = f.branches.find_by!(name: 'main').head_revision_id
    @s.merge('/f', target: 'main', source: 'feature', auto: true)

    found, revs = @s.new_since('/f', main_head)
    assert found
    assert_equal 1, revs.length                       # just the merge commit
    assert revs.first.merge_commit?
  end

  def test_fast_forward_onto_merge_commit_via_second_parent
    # Full-DAG ancestry: after merging feature into main (merge commit M with
    # second parent F), feature_head F IS an ancestor of M, so feature can be
    # fast-forwarded onto M. A first-parent-only walk would miss this.
    f = @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    feat_head = f.branches.find_by!(name: 'feature').head_revision_id
    @s.merge('/f', target: 'main', source: 'feature', auto: true)
    merge_commit = f.branches.find_by!(name: 'main').head_revision_id

    assert DbfsV2::Merge.fast_forward?(f, feat_head, merge_commit)
    res = @s.merge('/f', target: 'feature', source: 'main')
    assert res[:merged]
    assert_equal merge_commit, f.branches.find_by!(name: 'feature').head_revision_id
  end
end

class FlusherTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
    @root = "/tmp/dbfs2_flush_#{SecureRandom.hex(4)}"
    @fl = DbfsV2::Flusher.new(@s, @root)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_flush_text_content
    @s.create_file('/src/app.rb', content: "puts :hi\n")
    @fl.flush_all
    assert_equal "puts :hi\n", File.read(File.join(@root, 'src/app.rb'))
  end

  def test_flush_applies_mode
    @s.create_file('/x', content: 'x', mode: 0o640)
    @fl.flush_all
    mode = File.stat(File.join(@root, 'x')).mode & 0o777
    assert_equal 0o640, mode
  end

  def test_flush_symlink
    @s.create_file('/real', content: 'target')
    @s.create_symlink('/link', '/real')
    @fl.flush_all
    assert File.symlink?(File.join(@root, 'link'))
    assert_equal '/real', File.readlink(File.join(@root, 'link'))
  end

  # Binaries are not flushed (decisions #28).
  def test_flush_does_not_write_binaries
    @s.create_file('/b', binary: true, content: "\x00\x01\x02".b)
    @fl.flush_all
    refute File.exist?(File.join(@root, 'b')), 'binary must not be flushed'
  end
end

class AutoKeyframeIdempotencyTest < Minitest::Test
  include DbfsV2TestHelpers
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_manual_keyframe_then_auto_threshold_does_not_raise
    s = DbfsV2::Store.new(new_project_id, keyframe_revisions: 3, keyframe_bytes: 1_000_000)
    f = s.create_file('/f', content: '')
    s.read('/f')                              # hydrate cache
    3.times { |i| s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    s.keyframe('/f')                          # manual keyframe at the head auto would pick
    # next write crosses the threshold and would auto-keyframe the same head
    s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 3, data: 'y' }))
    assert_equal 'xxxy', s.read('/f')
    assert f.keyframes.count >= 1             # no RecordNotUnique
  end
end
