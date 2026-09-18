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
    r = ProjectFs.write_batch!(@s, '/f', [ins(0, 3, 'd'), ins(0, 4, 'e')])
    assert_equal :blind, r.mode
    assert_equal 2, r.revisions.size
    assert_equal "abcde\n", @s.read('/f')
  end

  def test_batch_at_the_head_appends_in_order
    @s.create_file('/f', content: "abc\n")
    base = head(@s, '/f')
    r = ProjectFs.write_batch!(@s, '/f', [ins(0, 3, 'd'), ins(0, 4, 'e')], base_revision_id: base)
    assert_equal :append, r.mode
    assert_equal "abcde\n", @s.read('/f')
    assert_equal base, r.revisions.first.parent_id
    assert_equal r.revisions.first.id, r.revisions.last.parent_id
    assert_equal ['main'], @s.find('/f').branches.pluck(:name)
  end

  # A stale batch is auto-branched at its base (as authored), then rebased onto
  # main one edit at a time.
  def test_stale_batch_auto_branches_and_rebases
    @s.create_file('/f', content: "one\ntwo\n")
    base = head(@s, '/f')
    @s.write('/f', ins(0, 0, 'X'))                                  # someone else, on main
    old_main = head(@s, '/f')
    r = ProjectFs.write_batch!(@s, '/f', [ins(1, 3, '!'), ins(1, 4, '?')], base_revision_id: base, user_id: 9)
    assert_equal :rebased, r.mode
    assert_equal "Xone\ntwo!?\n", @s.read('/f')
    assert r.branch.start_with?('auto/9/')
    assert_equal base, r.branch_revisions.first.parent_id, 'the batch is on its branch exactly as authored'
    assert_equal "one\ntwo!?\n", @s.read('/f', revision_id: r.branch_head)
    assert_equal old_main, r.revisions.first.parent_id, 'rebased onto main'
    assert_equal 2, r.revisions.size, 'one revision per edit'
    assert_equal r.branch_head, r.revisions.last.second_parent_id
    assert_equal r.revisions.last.id, head(@s, '/f')

    ack = ProjectFs.batch_ack('/f', r)
    assert_equal 'rebased', ack[:mode]
    assert_equal 'main', ack[:branch], 'the branch written to'
    assert_equal r.branch, ack[:auto_branch]
    assert_equal r.branch_head, ack[:auto_branch_head]
    assert_equal "Xone\ntwo!?\n", apply_specs("one\ntwo!?\n", ack[:changes]), 'author: its state -> head'
    frames = ProjectFs.batch_peer_frames('/f', r, user_id: 9)
    assert_equal old_main, frames.first[1][:parent]
    assert(frames.all? { |_cmd, f| f[:branch] == 'main' })
    view = "Xone\ntwo\n"
    frames.each { |_cmd, f| view = apply_specs(view, [f]) }
    assert_equal "Xone\ntwo!?\n", view, 'peers: old main -> head, frame by frame'

    # The author keeps typing from its own state (the branch head): the bridge
    # recorded on the rebased revision gets it there.
    @s.write('/f', ins(0, 0, 'Y'))
    r2 = ProjectFs.write_batch!(@s, '/f', [ins(1, 5, '#')], base_revision_id: r.branch_head, user_id: 9)
    assert_equal :rebased, r2.mode
    assert_equal "YXone\ntwo!?#\n", @s.read('/f')
  end

  # Two edits on one line against one concurrent edit between them: a content
  # merge would conflict; a rebase doesn't.
  def test_rebase_keeps_separate_edits_on_one_line_separate
    @s.create_file('/f', content: "abc def ghi\n")
    base = head(@s, '/f')
    @s.write('/f', ins(0, 5, 'Z'))
    r = ProjectFs.write_batch!(@s, '/f', [ins(0, 1, 'X'), ins(0, 11, 'Y')], base_revision_id: base)
    assert_equal :rebased, r.mode
    assert_equal "aXbc dZef ghYi\n", @s.read('/f')
  end

  def test_overlapping_stale_batch_raises_and_keeps_the_branch
    @s.create_file('/f', content: "abc\n")
    base = head(@s, '/f')
    @s.write('/f', d('replaceDataSingleLine', { startLine: 0, startChar: 0, endChar: 3, data: 'XYZ' }))
    main = head(@s, '/f')
    err = assert_raises(ProjectFs::BranchConflict) do
      ProjectFs.write_batch!(@s, '/f', [d('replaceDataSingleLine', { startLine: 0, startChar: 1, endChar: 2, data: 'q' })],
                             base_revision_id: base)
    end
    assert_equal main, head(@s, '/f'), 'main untouched'
    assert_equal "aqc\n", @s.read('/f', revision_id: err.branch_head), 'the edit is kept on its branch'
    assert @s.find('/f').branches.exists?(name: err.branch)
  end

  def test_unknown_base_is_refused
    @s.create_file('/f', content: "abc\n")
    @s.write('/f', ins(0, 0, 'X'))
    assert_raises(ProjectFs::UnknownBase) do
      ProjectFs.write_batch!(@s, '/f', [ins(0, 0, 'Y')], base_revision_id: SecureRandom.uuid)
    end
  end

  # A batch aimed at a named branch lands there and leaves main alone; a stale
  # one is rebased onto THAT branch's head, and the frames say which branch.
  def test_batch_on_a_named_branch
    @s.create_file('/f', content: "abc\n")
    main = head(@s, '/f')
    @s.branch('/f', 'topic')

    r = ProjectFs.write_batch!(@s, '/f', [ins(0, 3, 'd')], base_revision_id: main, branch: 'topic')
    assert_equal :append, r.mode
    assert_equal 'topic', r.target
    assert_equal "abcd\n", @s.read('/f', branch: 'topic')
    assert_equal "abc\n", @s.read('/f'), 'main untouched'
    assert_equal main, head(@s, '/f')
    assert_equal 'topic', ProjectFs.batch_ack('/f', r)[:branch]

    @s.write('/f', ins(0, 0, 'X'), branch: 'topic')                 # someone else, on topic
    r2 = ProjectFs.write_batch!(@s, '/f', [ins(0, 4, 'e')], base_revision_id: r.head, branch: 'topic')
    assert_equal :rebased, r2.mode
    assert_equal "Xabcde\n", @s.read('/f', branch: 'topic')
    assert_equal "abc\n", @s.read('/f'), 'main still untouched'
    frames = ProjectFs.batch_peer_frames('/f', r2, user_id: 1)
    assert(frames.all? { |_cmd, f| f[:branch] == 'topic' })

    assert_raises(ActiveRecord::RecordNotFound) do
      ProjectFs.write_batch!(@s, '/f', [ins(0, 0, 'Y')], base_revision_id: main, branch: 'nope')
    end
  end

  def apply_specs(text, specs)
    buf = DbfsV2::Buffer.new(text)
    specs.each { |c| buf.apply(DbfsV2::Delta.parse(c[:change_type], c[:change_data])) }
    buf.to_s
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
    assert_equal set.id, frame[:parent]
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
