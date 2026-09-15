# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class BufferTest < Minitest::Test
  def test_empty_buffer_is_one_empty_line
    b = DbfsV2::Buffer.new('')
    assert_equal [''], b.lines
    assert_equal '', b.to_s
  end

  def test_split_preserves_trailing_newline
    b = DbfsV2::Buffer.new("a\nb\n")
    assert_equal ['a', 'b', ''], b.lines
    assert_equal "a\nb\n", b.to_s
  end

  def test_offset_flattens_newlines
    b = DbfsV2::Buffer.new("ab\ncd")
    assert_equal 0, b.offset(0, 0)
    assert_equal 1, b.offset(0, 1)
    assert_equal 2, b.offset(0, 2)   # the '\n'
    assert_equal 3, b.offset(1, 0)   # 'c'
    assert_equal 5, b.offset(1, 2)
  end

  def test_position_inverts_offset
    b = DbfsV2::Buffer.new("ab\ncd")
    assert_equal [0, 0], b.position(0)
    assert_equal [0, 2], b.position(2)
    assert_equal [1, 0], b.position(3)
    assert_equal [1, 2], b.position(5)
  end

  def test_offset_clamps_out_of_range
    b = DbfsV2::Buffer.new('abc')
    assert_equal 3, b.offset(99, 99)
    assert_equal 0, b.offset(-5, -5)
  end
end
