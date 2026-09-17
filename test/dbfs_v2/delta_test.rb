# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class DeltaTest < Minitest::Test
  def b(str) = DbfsV2::Buffer.new(str)
  def d(type, p) = DbfsV2::Delta.new(type, p)

  def test_insert_single_line
    buf = b('ab')
    d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'X' }).apply_to(buf)
    assert_equal 'aXb', buf.to_s
  end

  def test_insert_multi_line
    buf = b("ab\ncd")
    d('insertDataMultiLine', { startLine: 0, startChar: 1, data: "X\nY" }).apply_to(buf)
    assert_equal "aX\nYb\ncd", buf.to_s
  end

  def test_delete_single_line
    buf = b('abcd')
    d('deleteDataSingleLine', { startLine: 0, startChar: 1, endChar: 3 }).apply_to(buf)
    assert_equal 'ad', buf.to_s
  end

  def test_delete_multi_line
    buf = b("a\nbb\nccc")
    d('deleteDataMultiLine', { startLine: 0, startChar: 1, endLine: 2, endChar: 1 }).apply_to(buf)
    assert_equal "acc", buf.to_s
  end

  def test_replace_single_line
    buf = b('abcdef')
    d('replaceDataSingleLine', { startLine: 0, startChar: 1, endChar: 4, data: 'XY' }).apply_to(buf)
    assert_equal 'aXYef', buf.to_s
  end

  def test_set_contents
    buf = b('old')
    d('setContents', { data: "new\nline" }).apply_to(buf)
    assert_equal "new\nline", buf.to_s
  end

  def test_range_of_insert_is_zero_width
    buf = b("ab\ncd")
    dlt = d('insertDataSingleLine', { startLine: 1, startChar: 1, data: 'X' })
    assert_equal [4, 4], dlt.range(buf)
  end

  def test_range_of_delete_spans_newline
    buf = b("ab\ncd")
    dlt = d('deleteDataMultiLine', { startLine: 0, startChar: 1, endLine: 1, endChar: 1 })
    assert_equal [1, 4], dlt.range(buf)
  end

  def test_deletion_insertion_replacement_predicates
    assert d('deleteDataSingleLine', {}).deletion?
    assert d('insertDataSingleLine', {}).insertion?
    assert d('replaceDataSingleLine', {}).replacement?
    assert d('setContents', {}).set_contents?
  end
end
