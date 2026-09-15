# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class CacheTest < Minitest::Test
  include DbfsV2TestHelpers

  def test_read_is_correct_after_many_writes
    s = DbfsV2::Store.new(new_project_id)
    s.create_file('/f.txt', content: '')
    s.read('/f.txt')                       # hydrate cache
    20.times { |i| s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    assert_equal 'x' * 20, s.read('/f.txt')
  end

  def test_cache_stays_coherent_after_transform
    s = DbfsV2::Store.new(new_project_id)
    f = s.create_file('/f.txt', content: 'X')
    s.read('/f.txt')                       # hydrate
    base = f.branches.find_by!(name: 'main').head_revision_id
    s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }), base_revision_id: base, priority: 'a')
    s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'B' }), base_revision_id: base, priority: 'b')
    assert_equal 'ABX', s.read('/f.txt')
  end

  def test_stat_size_uses_cache
    s = DbfsV2::Store.new(new_project_id)
    s.create_file('/f.txt', content: '')
    10.times { |i| s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    assert_equal 10, s.stat('/f.txt')[:size]
  end

  def test_auto_keyframe_on_revision_threshold
    s = DbfsV2::Store.new(new_project_id, keyframe_revisions: 5, keyframe_bytes: 1_000_000)
    f = s.create_file('/f.txt', content: '')
    s.read('/f.txt')                       # hydrate -> revs_since_kf = 0
    6.times { |i| s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    assert_equal 1, f.keyframes.count
    assert_equal 'xxxxxx', s.read('/f.txt')  # still correct
    assert_equal 6, f.revisions.count       # log never replaced
  end

  def test_auto_keyframe_on_byte_threshold
    s = DbfsV2::Store.new(new_project_id, keyframe_revisions: 1_000_000, keyframe_bytes: 10)
    f = s.create_file('/f.txt', content: '')
    s.read('/f.txt')
    s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'x' * 20 }))
    assert_equal 1, f.keyframes.count
  end

  def test_no_keyframe_below_threshold
    s = DbfsV2::Store.new(new_project_id, keyframe_revisions: 100, keyframe_bytes: 1_000_000)
    f = s.create_file('/f.txt', content: '')
    s.read('/f.txt')
    3.times { |i| s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    assert_equal 0, f.keyframes.count
  end

  def test_keyframe_accelerates_cold_read
    s = DbfsV2::Store.new(new_project_id, keyframe_revisions: 5, keyframe_bytes: 1_000_000)
    f = s.create_file('/f.txt', content: '')
    s.read('/f.txt')
    6.times { |i| s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: i, data: 'x' })) }
    # evict the cache so the next read replays from the keyframe
    DbfsV2::DocumentCache.invalidate_node(f.id)
    assert_equal 'xxxxxx', s.read('/f.txt')
  end
end
