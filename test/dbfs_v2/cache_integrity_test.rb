# frozen_string_literal: true
#
# Cache / keyframe invariants.
#
# The DocumentCache and keyframes are accelerators, never sources of truth. So:
# a keyframe's stored content must equal a from-genesis replay of its revision,
# and the keyframe policy must not fire on every keystroke.
require_relative 'dbfs_v2_test_helper'

class CacheIntegrityTest < Minitest::Test
  include StoreTestHelpers

  # Invariant: a keyframe's content must equal a from-genesis replay of its
  # revision. Keyframes are written from the in-memory cache, so a cache that
  # drifted (another process wrote between validation and lock) gets persisted.
  def test_every_keyframe_matches_full_replay_under_cross_process_write
    s = DbfsV2::Store.new(new_project_id, keyframe_revisions: 1)
    f = s.create_file('/f', content: 'a'); s.read('/f')
    fired = false
    me = self
    hook = Module.new do
      define_method(:validate_against!) do |buf|
        r = super(buf)
        unless fired
          fired = true
          me.foreign_write(f, DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'Z' }))
        end
        r
      end
    end
    delta = d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' })
    delta.singleton_class.prepend(hook)
    s.write('/f', delta)
    Keyframe.where(file_node_id: f.id).each do |kf|
      assert_equal replay_truth(f, kf.revision_id), kf.content, "keyframe at #{kf.revision_id} is not the replayed content"
    end
  end

  # KEYFRAME_BYTES compares bytes ADDED since the last keyframe, not total buffer
  # size, so every keystroke on a file larger than 64 KiB must not write a
  # full-content keyframe.
  def test_byte_threshold_does_not_keyframe_every_keystroke_on_large_files
    s = setup_store
    f = s.create_file('/big', content: 'x' * 70_000); s.read('/big')
    5.times { s.write('/big', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'y' })) }
    assert_operator Keyframe.where(file_node_id: f.id).count, :<=, 1
  end
end
