# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class TransformTest < Minitest::Test
  T = DbfsV2::Transform
  def b(str) = DbfsV2::Buffer.new(str)
  def d(type, p, pr = nil)
    x = DbfsV2::Delta.new(type, p)
    x.priority = pr if pr
    x
  end

  # Helper: apply both transformed results and assert convergence.
  def assert_converge(base, a, b)
    a2, b2 = T.transform(a, b, b(base))
    buf_a = b(base); a.apply_to(buf_a); b2.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k,_| k == :type }).apply_to(buf_a) }
    buf_b = b(base); b.apply_to(buf_b); a2.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k,_| k == :type }).apply_to(buf_b) }
    assert_equal buf_b.to_s, buf_a.to_s, "convergence failed\nA:#{buf_a.to_s.inspect}\nB:#{buf_b.to_s.inspect}"
    buf_a.to_s
  end

  def test_two_inserts_at_same_spot_tie_break
    a = d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }, 'a')
    b = d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'B' }, 'b')
    assert_equal 'ABX', assert_converge('X', a, b)
  end

  def test_insert_before_and_after
    a = d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }, 'a')
    b = d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'B' }, 'b')
    assert_equal 'AXB', assert_converge('X', a, b)
  end

  def test_delete_vs_insert_disjoint
    a = d('deleteDataSingleLine', { startLine: 0, startChar: 0, endChar: 1 }, 'a') # delete 'X'
    b = d('insertDataSingleLine', { startLine: 0, startChar: 2, data: 'B' }, 'b') # insert after
    assert_converge('XYZ', a, b)
  end

  def test_delete_vs_insert_inside_delete
    a = d('deleteDataSingleLine', { startLine: 0, startChar: 0, endChar: 3 }, 'a')
    b = d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'B' }, 'b')
    assert_converge('XYZ', a, b)
  end

  def test_delete_vs_delete_overlap
    a = d('deleteDataSingleLine', { startLine: 0, startChar: 0, endChar: 2 }, 'a')
    b = d('deleteDataSingleLine', { startLine: 0, startChar: 1, endChar: 3 }, 'b')
    assert_converge('XYZ', a, b)
  end

  def test_delete_vs_delete_disjoint
    a = d('deleteDataSingleLine', { startLine: 0, startChar: 0, endChar: 1 }, 'a')
    b = d('deleteDataSingleLine', { startLine: 0, startChar: 2, endChar: 3 }, 'b')
    assert_equal 'Y', assert_converge('XYZ', a, b)
  end

  def test_multiline_edits_converge
    a = d('insertDataMultiLine', { startLine: 0, startChar: 0, data: "A\n" }, 'a')
    b = d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'B' }, 'b')
    assert_converge("x\ny\n", a, b)
  end
end
