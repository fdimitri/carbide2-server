# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class PcreTest < Minitest::Test
  include DbfsV2TestHelpers

  def b(str) = DbfsV2::Buffer.new(str)
  def d(type, p) = DbfsV2::Delta.new(type, p)

  def test_replace_all_single_line
    buf = b('foo bar foo')
    d('pcreReplaceSingleLine', { pattern: 'foo', replacement: 'X' }).apply_to(buf)
    assert_equal 'X bar X', buf.to_s
  end

  def test_replace_bounded_limit
    buf = b('foo foo foo')
    d('pcreReplaceSingleLine', { pattern: 'foo', replacement: 'X', limit: 2 }).apply_to(buf)
    assert_equal 'X X foo', buf.to_s
  end

  def test_limit_zero_means_unlimited
    buf = b('a a a a')
    d('pcreReplaceSingleLine', { pattern: 'a', replacement: 'b', limit: 0 }).apply_to(buf)
    assert_equal 'b b b b', buf.to_s
  end

  def test_backreference_numbered
    buf = b('hello world')
    d('pcreReplaceSingleLine', { pattern: '(\\w+) (\\w+)', replacement: '\\2 \\1' }).apply_to(buf)
    assert_equal 'world hello', buf.to_s
  end

  def test_backreference_php_style
    buf = b('hello world')
    d('pcreReplaceSingleLine', { pattern: '(\\w+) (\\w+)', replacement: '$2 $1' }).apply_to(buf)
    assert_equal 'world hello', buf.to_s
  end

  def test_named_backreference
    buf = b('abc')
    d('pcreReplaceSingleLine', { pattern: '(?<x>a)', replacement: '\\k<x>\\k<x>' }).apply_to(buf)
    assert_equal 'aabc', buf.to_s
  end

  def test_multiline_match_spans_newline
    buf = b("foo\nbar\nfoo\nbar")
    d('pcreReplaceMultiLine', { pattern: 'foo\\nbar', replacement: 'Z' }).apply_to(buf)
    assert_equal "Z\nZ", buf.to_s
  end

  def test_single_line_does_not_span_newline
    # explicit \n in pattern still won't match in single-line mode
    buf = b("foo\nbar")
    d('pcreReplaceSingleLine', { pattern: 'foo\\nbar', replacement: 'Z' }).apply_to(buf)
    assert_equal "foo\nbar", buf.to_s
  end

  # A pattern that can match empty at the end of the text used to loop forever
  # with limit 0 (Regexp#match(str, len + 1) still matches at len). Replacing
  # must terminate and agree with String#gsub.
  def test_zero_width_matches_terminate_and_match_gsub
    require 'timeout'
    ['', 'x*', '$', '^', 'a*', '\\b', '(?=b)'].each do |pat|
      ["ab", "aab\nb", ''].each do |text|
        %w[pcreReplaceSingleLine pcreReplaceMultiLine].each do |type|
          buf = b(text)
          Timeout.timeout(2) { d(type, { pattern: pat, replacement: '-' }).apply_to(buf) }
          re = Regexp.new(pat, type == 'pcreReplaceMultiLine' ? Regexp::MULTILINE : 0)
          assert_equal text.gsub(re, '-'), buf.to_s, "#{type} #{pat.inspect} on #{text.inspect}"
        end
      end
    end
  end

  def test_store_persists_pcre_revision
    s = DbfsV2::Store.new(new_project_id)
    s.create_file('/f', content: 'foo foo')
    s.write('/f', d('pcreReplaceSingleLine', { pattern: 'foo', replacement: 'X', limit: 1 }))
    assert_equal 'X foo', s.read('/f')
  end

  def test_pcre_replaces_ot_converge
    tr = DbfsV2::Transform
    base = 'abc abc'
    a = d('pcreReplaceSingleLine', { pattern: 'abc', replacement: 'X' })
    a.priority = 'a'
    c = DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'Z' })
    c.priority = 'c'
    a2, c2 = tr.transform(a, c, b(base))
    buf_a = b(base); a.apply_to(buf_a); c2.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k,_| k == :type }).apply_to(buf_a) }
    buf_b = b(base); c.apply_to(buf_b); a2.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k,_| k == :type }).apply_to(buf_b) }
    assert_equal buf_b.to_s, buf_a.to_s
  end
end
