# frozen_string_literal: true
#
# TP1 convergence property test.
#
# TP1 is the correctness condition every OT transform must satisfy:
#
#     apply(apply(s, a), T(b, a))  ==  apply(apply(s, b), T(a, b))
#
# Two sites that saw the same base state and applied concurrent operations in
# opposite orders must end up with the same document. If this fails, clients
# silently diverge; there is no error, just two different files.
#
# Runs as part of the suite (rake test), via the shared test_helper.
#
require_relative 'dbfs_v2_test_helper'
 
class Tp1Test < Minitest::Test
  T = DbfsV2::Transform
  B = DbfsV2::Buffer
  D = DbfsV2::Delta
 
  BASES = ['abc', 'ab', 'abcd', "ab\ncd", "a\nb"].freeze
 
  def mk(type, payload, pri)
    d = D.new(type, payload)
    d.priority = pri
    d
  end
 
  def apply_hashes(buf, hashes)
    hashes.each { |h| D.new(h[:type], h.reject { |k, _| k == :type }).apply_to(buf) }
    buf
  end
 
  # Returns [left, right]; TP1 holds iff they are equal.
  def converge(base, a, b)
    a_prime, b_prime = T.transform(a, b, B.new(base))
    left  = B.new(base); a.apply_to(left);  apply_hashes(left,  b_prime)
    right = B.new(base); b.apply_to(right); apply_hashes(right, a_prime)
    [left.to_s, right.to_s]
  end
 
  # --- op generators -------------------------------------------------------
 
  def inserts(base, pri)
    buf = B.new(base)
    (0..base.length).flat_map do |o|
      l, c = buf.position(o)
      [mk('insertDataMultiLine', { startLine: l, startChar: c, data: 'Z' }, pri),
       mk('insertDataMultiLine', { startLine: l, startChar: c, data: "Z\nW" }, pri)]
    end
  end
 
  def ranges(base)
    buf = B.new(base)
    (0..base.length).flat_map do |s|
      ((s + 1)..base.length).map do |e|
        sl, sc = buf.position(s)
        el, ec = buf.position(e)
        { startLine: sl, startChar: sc, endLine: el, endChar: ec }
      end
    end
  end
 
  def deletes(base, pri)
    ranges(base).map { |r| mk('deleteDataMultiLine', r, pri) }
  end
 
  def replaces(base, pri)
    ranges(base).map { |r| mk('replaceDataMultiLine', r.merge(data: 'R'), pri) }
  end

  def setcontents(base, pri)
    [mk('setContents', { data: 'P' }, pri), mk('setContents', { data: "Q\nZ" }, pri)]
  end

  def pcre(base, pri)
    [mk('pcreReplaceSingleLine', { pattern: 'a', replacement: 'X' }, pri),
     mk('pcreReplaceSingleLine', { pattern: 'b', replacement: 'Y', limit: 1 }, pri)]
  end
 
  # --- the property --------------------------------------------------------
 
  def assert_tp1_over(a_ops_for, b_ops_for, label)
    failures = []
    checked  = 0
    BASES.each do |base|
      a_ops = a_ops_for.call(base, 'a')
      b_ops = b_ops_for.call(base, 'b')
      a_ops.each do |a|
        b_ops.each do |b|
          checked += 1
          left, right = converge(base, a, b)
          next if left == right
          failures << [base, a, b, left, right]
        end
      end
    end
    # Guard against a generator silently returning no ops (which would make
    # this property test assert nothing and pass vacuously).
    assert_operator checked, :>, 0, "#{label}: no op pairs were generated"
    return if failures.empty?

    sample = failures.first(5).map do |base, a, b, l, r|
      "  base=#{base.inspect}\n" \
      "    a = #{a.type} #{a.payload.inspect}\n" \
      "    b = #{b.type} #{b.payload.inspect}\n" \
      "    a then b' => #{l.inspect}\n" \
      "    b then a' => #{r.inspect}"
    end.join("\n")
 
    flunk "#{label}: TP1 violated in #{failures.size} of #{checked} pairs\n#{sample}"
  end
 
  def test_tp1_insert_vs_insert
    assert_tp1_over method(:inserts).to_proc, method(:inserts).to_proc, 'insert x insert'
  end
 
  def test_tp1_insert_vs_delete
    assert_tp1_over method(:inserts).to_proc, method(:deletes).to_proc, 'insert x delete'
  end
 
  def test_tp1_delete_vs_insert
    assert_tp1_over method(:deletes).to_proc, method(:inserts).to_proc, 'delete x insert'
  end
 
  def test_tp1_delete_vs_delete
    assert_tp1_over method(:deletes).to_proc, method(:deletes).to_proc, 'delete x delete'
  end
 
  def test_tp1_insert_vs_replace
    assert_tp1_over method(:inserts).to_proc, method(:replaces).to_proc, 'insert x replace'
  end
 
  def test_tp1_delete_vs_replace
    assert_tp1_over method(:deletes).to_proc, method(:replaces).to_proc, 'delete x replace'
  end
 
  def test_tp1_replace_vs_replace
    assert_tp1_over method(:replaces).to_proc, method(:replaces).to_proc, 'replace x replace'
  end

  def test_tp1_setcontents_vs_insert
    assert_tp1_over method(:setcontents).to_proc, method(:inserts).to_proc, 'setContents x insert'
  end

  def test_tp1_setcontents_vs_delete
    assert_tp1_over method(:setcontents).to_proc, method(:deletes).to_proc, 'setContents x delete'
  end

  def test_tp1_setcontents_vs_replace
    assert_tp1_over method(:setcontents).to_proc, method(:replaces).to_proc, 'setContents x replace'
  end

  def test_tp1_setcontents_vs_setcontents
    assert_tp1_over method(:setcontents).to_proc, method(:setcontents).to_proc, 'setContents x setContents'
  end

  def test_tp1_pcre_vs_insert
    assert_tp1_over method(:pcre).to_proc, method(:inserts).to_proc, 'pcre x insert'
  end

  def test_tp1_pcre_vs_replace
    assert_tp1_over method(:pcre).to_proc, method(:replaces).to_proc, 'pcre x replace'
  end

  def test_tp1_pcre_vs_pcre
    assert_tp1_over method(:pcre).to_proc, method(:pcre).to_proc, 'pcre x pcre'
  end

  # transform(a,b) and transform(b,a) must converge to the SAME document (two
  # unordered concurrent edits). Catches opaque paths that apply one fixed
  # order regardless of argument order.
  def test_transform_is_argument_order_independent
    gen = ->(base, pri) { inserts(base, pri) + deletes(base, pri) + replaces(base, pri) + setcontents(base, pri) + pcre(base, pri) }
    checked = 0
    BASES.each do |base|
      gen.call(base, 'a').each do |a|
        gen.call(base, 'b').each do |b|
          checked += 1
          ab = converge(base, a, b).first
          ba = converge(base, b, a).first
          assert_equal ab, ba, "order-dependent: base=#{base.inspect} a=#{a.type} b=#{b.type} => #{ab.inspect} vs #{ba.inspect}"
        end
      end
    end
    assert_operator checked, :>, 0, 'no pairs checked'
  end
 
  # --- tie-break determinism ----------------------------------------------
  #
  # The transform's insert-vs-insert tie-break reads delta.priority. Store
  # assigns a fresh SecureRandom.uuid when the caller supplies none, so the
  # same pair of concurrent ops can resolve either way run to run.
 
  def test_tie_break_is_deterministic
    # The same pair of concurrent ops must converge to the same document no
    # matter how many times we recompute it (deterministic priority = content
    # hash via priority_for, not a random UUID).
    outcomes = 100.times.map do
      a = mk('insertDataMultiLine', { startLine: 0, startChar: 0, data: 'I' }, nil)
      b = mk('insertDataMultiLine', { startLine: 0, startChar: 0, data: 'C' }, nil)
      a.priority = a.priority_for(nil)
      b.priority = b.priority_for(nil)
      converge('abc', a, b).first
    end.uniq
    assert_equal 1, outcomes.size,
                 "same concurrent ops produced #{outcomes.size} different documents: #{outcomes.inspect}"
  end
end