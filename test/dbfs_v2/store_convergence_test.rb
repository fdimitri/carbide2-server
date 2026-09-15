# frozen_string_literal: true
#
# Store-level convergence (TP1 through the production write path).
#
# tp1_test.rb exercises `Transform.transform` pairwise — which nothing in lib/
# calls. The production paths are:
#
#   * live write — Store#apply_transformed! (folds Transform.transform_list past
#                  each intervening revision, gated by ambiguous?)
#   * merge      — Merge#auto_merge_content (diff_prims + transform_list)
#
# Neither had TP1 coverage. This drives the live path end to end: for a pair of
# concurrent ops, commit them in both orders through the Store and assert both
# orders reach the same document — or BOTH surface a ConflictError. Never one
# success and one conflict, never divergence.
#
# Ops include setContents (now diffable) and pcre (now expanded into splices
# against the base), because both are on the live path and behave differently
# there than in the pairwise transform().
require_relative 'dbfs_v2_test_helper'

class StoreConvergenceTest < Minitest::Test
  include StoreTestHelpers

  BASES = ['0123456789', "ab\ncd"].freeze

  # Each pair builds two stores and does four writes; sample the op set
  # deterministically so the store tests stay fast while still covering every op
  # kind at several offsets.
  STRIDE = 4

  def sample(ops) = ops.each_with_index.select { |_, i| (i % STRIDE).zero? }.map(&:first)

  def deltas_for(base, pri)
    buf = DbfsV2::Buffer.new(base)
    inserts = (0..base.length).map do |o|
      l, c = buf.position(o)
      DbfsV2::Delta.new('insertDataMultiLine', { startLine: l, startChar: c, data: 'Z' })
    end
    deletes = []
    (0...base.length).each do |s|
      ((s + 1)..base.length).each do |e|
        sl, sc = buf.position(s)
        el, ec = buf.position(e)
        deletes << DbfsV2::Delta.new('deleteDataMultiLine',
                                     { startLine: sl, startChar: sc, endLine: el, endChar: ec })
      end
    end
    ops = sample(inserts) + sample(deletes)
    ops.each { |o| o.priority = pri }
    ops
  end

  def setcontents_ops(base, pri)
    # A diffable change (prepend a header) and a full rewrite.
    [DbfsV2::Delta.new('setContents', { data: "H\n#{base}" }),
     DbfsV2::Delta.new('setContents', { data: base.upcase })].each { |o| o.priority = pri }
  end

  def pcre_ops(base, pri)
    return [] unless base =~ /[a-z]/
    [DbfsV2::Delta.new('pcreReplaceSingleLine', { pattern: base[0], replacement: 'Q' })].each { |o| o.priority = pri }
  end

  # Commit `first`, then `second` with the pre-first base (a stale edit).
  # Returns [:ok, content] or [:conflict].
  def run_order(base, first:, second:)
    s = setup_store
    s.create_file('/f', content: base)
    pre = head(s, '/f')
    s.write('/f', first)
    s.write('/f', second, base_revision_id: pre)
    [:ok, s.read('/f')]
  rescue DbfsV2::ConflictError
    [:conflict]
  end

  def assert_converges(base, a, b, label)
    r1 = run_order(base, first: b, second: a)
    r2 = run_order(base, first: a, second: b)

    if r1[0] != r2[0]
      flunk "#{label}: one order committed, the other conflicted " \
            "(base=#{base.inspect} a=#{a.to_h} b=#{b.to_h}) => #{r1.inspect} / #{r2.inspect}"
    end
    return if r1[0] == :conflict # both refused: consistent

    assert_equal r1[1], r2[1],
                 "#{label}: divergence\n  base=#{base.inspect}\n  a=#{a.to_h}\n  b=#{b.to_h}\n" \
                 "  => #{r1[1].inspect} vs #{r2[1].inspect}"
  end

  def check_pairs(aops_for, bops_for, label)
    checked = 0
    BASES.each do |base|
      aops_for.call(base, 'a').each do |a|
        bops_for.call(base, 'b').each do |b|
          checked += 1
          assert_converges(base, a, b, label)
        end
      end
    end
    assert_operator checked, :>, 0, 'no pairs checked'
  end

  def test_tp1_through_store_insert_and_delete
    check_pairs(method(:deltas_for), method(:deltas_for), 'ins/del')
  end

  def test_tp1_through_store_with_setcontents
    check_pairs(method(:setcontents_ops),
                ->(base, pri) { deltas_for(base, pri) + setcontents_ops(base, pri) },
                'setContents')
  end

  def test_tp1_through_store_with_pcre
    check_pairs(method(:pcre_ops),
                ->(base, pri) { deltas_for(base, pri) + setcontents_ops(base, pri) + pcre_ops(base, pri) },
                'pcre')
  end
end
