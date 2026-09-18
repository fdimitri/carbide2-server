# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# Diff3 is the text a human starts from once auto-merge has refused; these pin
# what it takes silently and what it marks.
class Diff3Test < Minitest::Test
  D3 = DbfsV2::Diff3

  def test_disjoint_changes_merge_silently
    base   = "a\nb\nc\nd\ne\n"
    ours   = "A\nb\nc\nd\ne\n"
    theirs = "a\nb\nc\nd\nE\n"
    r = D3.merge(base, ours, theirs)
    assert_equal "A\nb\nc\nd\nE\n", r[:text]
    assert_equal 0, r[:conflicts]
  end

  def test_same_change_on_both_sides_is_taken_once
    base = "a\nb\n"
    r = D3.merge(base, "a\nX\n", "a\nX\n")
    assert_equal "a\nX\n", r[:text]
    assert_equal 0, r[:conflicts]
  end

  def test_overlapping_changes_are_marked_with_both_sides_and_located
    base   = "one\ntwo\nthree\n"
    ours   = "one\nOURS\nthree\n"
    theirs = "one\nTHEIRS\nthree\n"
    r = D3.merge(base, ours, theirs, labels: %w[main feature])
    assert_equal 1, r[:conflicts]
    assert_equal "one\n<<<<<<< main\nOURS\n=======\nTHEIRS\n>>>>>>> feature\nthree\n", r[:text]
    b = r[:blocks].first
    assert_equal [1, 6], [b.start_line, b.end_line]
    assert_equal "OURS\n",   b.ours
    assert_equal "THEIRS\n", b.theirs
    assert_equal "two\n",    b.base
    assert_equal "<<<<<<< main\n", r[:text].lines[b.start_line]
    assert_equal ">>>>>>> feature\n", r[:text].lines[b.end_line - 1]
  end

  def test_delete_versus_modify_conflicts_and_one_sided_delete_does_not
    base = "a\nb\nc\n"
    r = D3.merge(base, "a\nc\n", "a\nB\nc\n")
    assert_equal 1, r[:conflicts]
    assert_equal "", r[:blocks].first.ours
    r = D3.merge(base, "a\nc\n", "a\nb\nc\nd\n")
    assert_equal "a\nc\nd\n", r[:text]
  end

  def test_inserts_at_the_same_spot_conflict_and_a_missing_final_newline_does_not_eat_a_marker
    r = D3.merge("a\nb", "a\nX\nb", "a\nY\nb")
    assert_equal 1, r[:conflicts]
    assert_includes r[:text], "=======\n"
    # The unterminated "b" became "b\n" on both sides, so it is inside the hunk.
    r = D3.merge("a\nb", "a\nb\nours-tail", "a\nb\ntheirs-tail")
    assert_equal 1, r[:conflicts]
    assert_equal "a\n<<<<<<< ours\nb\nours-tail\n=======\nb\ntheirs-tail\n>>>>>>> theirs\n", r[:text]
  end

  def test_empty_base_is_an_add_add
    r = D3.merge('', "x\n", "x\n")
    assert_equal "x\n", r[:text]
    r = D3.merge('', "x\n", "y\n")
    assert_equal 1, r[:conflicts]
    r = D3.merge('', '', "y\n")
    assert_equal "y\n", r[:text]
  end
end
