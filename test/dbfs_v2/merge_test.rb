# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class MergeTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_fast_forward_moves_pointer
    @s.create_file('/f', content: "a\n")
    @s.branch('/f', 'feature')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'b' }), branch: 'feature')
    res = @s.merge('/f', target: 'main', source: 'feature')
    assert res[:merged]
    assert_equal "a\nb", @s.read('/f', branch: 'main')
    assert_equal @s.branches('/f').find { |b| b[:name] == 'feature' }[:head],
                 @s.branches('/f').find { |b| b[:name] == 'main' }[:head]
  end

  def test_diverged_is_not_fast_forward
    @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    res = @s.merge('/f', target: 'main', source: 'feature')
    refute res[:merged]
    assert_equal 'not a fast-forward; resolve manually', res[:reason]
  end

  def test_user_resolved_merge_commit_has_two_parents
    @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    rev = @s.merge('/f', target: 'main', source: 'feature', resolved: "x\nmf\n")
    assert rev.merge_commit?
    assert rev.parent_id
    assert rev.second_parent_id
    refute_equal rev.parent_id, rev.second_parent_id
    assert_equal "x\nmf\n", @s.read('/f', branch: 'main')
  end

  def test_merge_commit_is_reconstructable
    f = @s.create_file('/f', content: "x\n")
    @s.branch('/f', 'feature')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')
    rev = @s.merge('/f', target: 'main', source: 'feature', resolved: "x\nmf\n")
    assert_equal "x\nmf\n", DbfsV2::Content.at(f, rev.id)
  end
end
