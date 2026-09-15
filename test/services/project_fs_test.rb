# frozen_string_literal: true
#
# ProjectFs — the carbide2 seam over DBFS v2. Worker-side behavior (watcher,
# flusher, FsStore) is covered end to end by carbide2-worker's
# test/dbfs_integration_test.rb; this pins the pieces the seam owns.
require_relative '../dbfs_v2/dbfs_v2_test_helper'
require 'tmpdir'

class ProjectFsTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @project = Project.create!(name: "pfs-#{SecureRandom.hex(4)}", uuid: SecureRandom.uuid)
    @s = ProjectFs.store(@project.id)
  end

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })

  def test_tree_json_keeps_the_v1_wire_shape
    @s.create_file('/b.txt', content: 'b')
    @s.create_file('/A.txt', content: 'a')
    @s.create_folder('/zdir')
    @s.create_file('/gone.txt', content: 'x')
    @s.delete('/gone.txt')
    tree = ProjectFs.tree_json(@project.id)
    assert_equal '/', tree[:path]
    assert_equal %w[zdir A.txt b.txt], tree[:children].map { |c| c[:name] }, 'folders first, then case-insensitive name; tombstones hidden'
    file = tree[:children].find { |c| c[:name] == 'A.txt' }
    refute file.key?(:children), 'files carry no children key'
    assert_equal({ id: file[:id], name: 'A.txt', path: '/A.txt', type: 'file', binary: false, symlink: false }, file)
    assert_equal [], ProjectFs.tree_json(Project.create!(name: 'empty', uuid: SecureRandom.uuid).id)
  end

  def test_blind_batch_applies_each_change_at_the_head
    @s.create_file('/f', content: "abc\n")
    revs = ProjectFs.write_batch!(@s, '/f', [ins(0, 3, 'd'), ins(0, 4, 'e')])
    assert_equal 2, revs.size
    assert_equal "abcde\n", @s.read('/f')
  end

  def test_anchored_batch_chains_its_changes
    @s.create_file('/f', content: "abc\n")
    base = head(@s, '/f')
    ProjectFs.write_batch!(@s, '/f', [ins(0, 3, 'd'), ins(0, 4, 'e')], base_revision_id: base)
    assert_equal "abcde\n", @s.read('/f')
  end

  def test_anchored_single_change_is_transformed_past_a_concurrent_write
    @s.create_file('/f', content: "abc\n")
    base = head(@s, '/f')
    @s.write('/f', ins(0, 0, 'X'))
    ProjectFs.write_batch!(@s, '/f', [ins(0, 3, '!')], base_revision_id: base)
    assert_equal "Xabc!\n", @s.read('/f')
  end

  def test_stale_anchored_batch_is_refused_whole
    @s.create_file('/f', content: "abc\n")
    base = head(@s, '/f')
    @s.write('/f', ins(0, 0, 'X'))
    before = Revision.where(file_node_id: @s.find('/f').id).count
    assert_raises(DbfsV2::ConflictError) do
      ProjectFs.write_batch!(@s, '/f', [ins(0, 3, 'd'), ins(0, 4, 'e')], base_revision_id: base)
    end
    assert_equal "Xabc\n", @s.read('/f')
    assert_equal before, Revision.where(file_node_id: @s.find('/f').id).count
  end

  def test_revision_frames
    @s.create_file('/f', content: "abc\n")
    set = Revision.find(head(@s, '/f'))
    cmd, frame = ProjectFs.revision_frame('/f', set, user_id: 7)
    assert_equal 'set_contents', cmd
    assert_equal "abc\n", frame[:content]
    rev = @s.write('/f', ins(0, 1, 'Z')).first
    cmd, frame = ProjectFs.revision_frame('/f', rev, user_id: 7)
    assert_equal 'change', cmd
    assert_equal 'insertDataSingleLine', frame[:change_type]
    assert_equal({ 'startLine' => 0, 'startChar' => 1, 'data' => 'Z' }, JSON.parse(frame[:change_data]))
    assert_equal rev.id, frame[:revision]
  end

  def test_ensure_helpers_are_idempotent
    a = ProjectFs.ensure_file!(@s, '/x/y.txt', content: 'one')
    b = ProjectFs.ensure_file!(@s, '/x/y.txt', content: 'two')
    assert_equal a.id, b.id
    assert_equal 'one', @s.read('/x/y.txt')
    assert_equal @s.find('/x').id, ProjectFs.ensure_folder!(@s, '/x').id
    assert_raises(RuntimeError) { ProjectFs.ensure_folder!(@s, '/x/y.txt') }
  end

  def test_record_disk_stat_and_oversized_tracking
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'tool.sh')
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o750, path)
      node = @s.create_file('/tool.sh', content: "#!/bin/sh\n")
      ProjectFs.record_disk_stat!(node, path)
      node.reload
      assert_equal 0o750, node.posix_mode
      assert_equal File.stat(path).uid.to_s, (Etc.getpwnam(node.owner).uid.to_s rescue node.owner)

      big = @s.create_file('/big.log', content: 'was text')
      ProjectFs.track_oversized!(@s, '/big.log', path)
      big.reload
      assert big.binary?, 'flipped to binary so the flusher never truncates it'
      assert_equal 'was text', @s.read('/big.log', revision_id: head(@s, '/big.log')), 'text history stays readable'
    end
  end
end
