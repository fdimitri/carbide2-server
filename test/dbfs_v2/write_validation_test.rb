# frozen_string_literal: true
#
# Write validation — fail closed, never poison a file.
#
# A bad delta must be rejected BEFORE the revision commits, so it cannot leave a
# revision that every later read raises on, and out-of-range/inverted
# coordinates are refused rather than silently clamped.
require_relative 'dbfs_v2_test_helper'

class WriteValidationTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  # validate_against! compiles the pattern AND expands the replacement, so an
  # unknown backreference fails closed before the write commits. Otherwise the
  # revision lands and every later cold read of the file raises.
  def test_bad_named_backreference_fails_closed_and_does_not_poison_the_file
    f = @s.create_file('/f', content: 'abc')
    assert_raises(StandardError) do
      @s.write('/f', d('pcreReplaceSingleLine', { pattern: 'a', replacement: '${nope}' }))
    end
    DbfsV2::DocumentCache.invalidate_node(f.id)
    assert_equal 1, Revision.where(file_node_id: f.id).count
    assert_equal 'abc', @s.read('/f')
  end

  # An inverted range (end before start) is a loud failure, not a silent no-op.
  def test_inverted_range_is_rejected
    @s.create_file('/f', content: "abc\ndef")
    assert_raises(ArgumentError) do
      @s.write('/f', d('deleteDataMultiLine', { startLine: 1, startChar: 2, endLine: 0, endChar: 1 }))
    end
  end
end
