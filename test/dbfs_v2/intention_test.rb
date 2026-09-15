# frozen_string_literal: true
#
# Intention preservation.
#
# The "I" in the CCI model (convergence, causality, intention): after a
# concurrent op is transformed away, each site's edit still does what its author
# meant. This is NOT TP2.
#
#   * TP1 (tp1_test.rb) is the 2-operation convergence property.
#   * TP2 is the 3-operation convergence property (c transformed past a then b'
#     vs past b then a'). We do NOT test TP2 — see docs/decisions.md #20: this
#     transform violates it, and this architecture does not need it (every write
#     serializes through the branch row lock, so each op is transformed along
#     exactly one path — the Jupiter / single-total-order model, where TP1 alone
#     suffices).
#   * This file is the intention-preservation oracle from the first review.
#
# Driven through the Store, not the bare transform: commit concurrent revisions,
# then send an op with a stale base so it exercises apply_transformed! over
# multiple hops (that is where the split-delta bug lived). The pairwise
# transform() is already covered by tp1_test.rb.
require_relative 'dbfs_v2_test_helper'

class IntentionTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store

  # A stale insert, transformed past TWO intervening revisions, keeps its text.
  def test_insert_intention_survives_multiple_concurrent_revisions
    @s.create_file('/f', content: '0123456789')
    base = head(@s, '/f')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'B' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 5, data: 'Z' }), base_revision_id: base)

    out = @s.read('/f')
    assert_includes out, 'Z', "intended insert lost: #{out.inspect}"
    assert_includes out, 'A', "concurrent edit lost: #{out.inspect}"
    assert_includes out, 'B', "concurrent edit lost: #{out.inspect}"
    # 0..9 must all still be present, with the three inserts interleaved.
    '0123456789'.each_char { |c| assert_includes out, c, "base char #{c} lost: #{out.inspect}" }
  end

  # A stale delete, transformed past two intervening revisions, still removes its
  # range (and the concurrent inserts survive).
  def test_delete_intention_survives_multiple_concurrent_revisions
    @s.create_file('/f', content: 'abcdefgh')
    base = head(@s, '/f')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'X' }))
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'Y' }))
    # stale delete of "cdef" (offsets 2..6 in the base)
    @s.write('/f', d('deleteDataSingleLine', { startLine: 0, startChar: 2, endChar: 6 }), base_revision_id: base)

    out = @s.read('/f')
    refute_includes out, 'cdef', "intended delete lost: #{out.inspect}"
    assert_includes out, 'X', "concurrent edit lost: #{out.inspect}"
    assert_includes out, 'Y', "concurrent edit lost: #{out.inspect}"
    assert_includes out, 'ab', "unaffected base text lost: #{out.inspect}"
    assert_includes out, 'gh', "unaffected base text lost: #{out.inspect}"
  end

  # An edit that OVERLAPS a concurrent full rewrite cannot be reconciled without
  # guessing intention, so the live path must surface it as a ConflictError and
  # commit nothing (not silently relocate the edit, and not the opaque snapshot
  # that the bare transform() would produce).
  def test_overlapping_write_is_a_conflict_and_commits_nothing
    @s.create_file('/f', content: "hello\nworld")
    base = head(@s, '/f')
    @s.write('/f', d('setContents', { data: "HELLO\nWORLD" }))   # concurrent full rewrite
    before = Revision.where(file_node_id: @s.find('/f').id).count

    assert_raises(DbfsV2::ConflictError) do
      @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 2, data: '!' }), base_revision_id: base)
    end
    assert_equal before, Revision.where(file_node_id: @s.find('/f').id).count,
                 'a conflicting write must not commit a revision'
    assert_equal "HELLO\nWORLD", @s.read('/f')
  end
end
