# frozen_string_literal: true
#
# Direct tests for the diff that feeds setContents decomposition and three-way
# merge. The OT regression suite only caught a diff bug indirectly (via a
# position shift); these pin the diff itself.
require_relative 'dbfs_v2_test_helper'
require 'timeout'

class DiffTest < Minitest::Test
  def d_prims(old, new) = DbfsV2::Transform.diff_prims(old, new, 'p')

  # Apply a prim list (all in one coordinate space) to `old`, returning content.
  def apply(old, prims)
    buf = DbfsV2::Buffer.new(old)
    DbfsV2::Merge.apply_prims(buf, prims)
    buf.to_s
  end

  # --- exact shapes ---------------------------------------------------------

  # The whole old content is a SUFFIX of the new content, so the only minimal
  # diff is a single insert of the header at 0 (no tie to break).
  def test_inserted_prefix_is_one_insert_at_zero
    prims = d_prims("hello\nworld", "# header\nhello\nworld")
    assert_equal 1, prims.size
    p0 = prims.first
    assert_equal 0, p0.start
    assert_equal 0, p0.finish
    assert_equal "# header\n", p0.text
  end

  def test_deleted_suffix_is_one_delete
    prims = d_prims("a\nb\nc\n", "a\nb\n")
    assert_equal 1, prims.size
    assert prims.first.delete?
    assert_equal "a\nb\n", apply("a\nb\nc\n", prims)
  end

  def test_identical_is_empty
    assert_equal [], d_prims("same\ntext", "same\ntext")
  end

  # --- round-trip (the core invariant) --------------------------------------

  def test_round_trip_random
    srand(1234)
    alphabet = ["a", "b", "c", "d", "\n"]
    2000.times do
      old = Array.new(rand(0..30)) { alphabet.sample }.join
      new = Array.new(rand(0..30)) { alphabet.sample }.join
      prims = d_prims(old, new)
      assert_equal new, apply(old, prims),
                   "round-trip failed\nold=#{old.inspect}\nnew=#{new.inspect}\nprims=#{prims.map(&:to_a).inspect}"
    end
  end

  # --- minimality -----------------------------------------------------------

  # Minimal edit cost is O(n + m - 2*LCS). Myers must reach it.
  def test_myers_is_minimal
    srand(99)
    alphabet = ["a", "b", "c"]
    500.times do
      a = Array.new(rand(0..16)) { alphabet.sample }
      b = Array.new(rand(0..16)) { alphabet.sample }
      hunks = DbfsV2::Myers.hunks(a, b)
      next if hunks.nil?

      cost = hunks.sum { |os, oe, ns, ne| (oe - os) + (ne - ns) }
      minimal = a.length + b.length - 2 * lcs_length(a, b)
      assert_equal minimal, cost,
                   "non-minimal diff\na=#{a.inspect}\nb=#{b.inspect}\nhunks=#{hunks.inspect}"
    end
  end

  def lcs_length(a, b)
    n = a.length
    m = b.length
    dp = Array.new(n + 1) { Array.new(m + 1, 0) }
    (n - 1).downto(0) do |i|
      (m - 1).downto(0) do |j|
        dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : [dp[i + 1][j], dp[i][j + 1]].max
      end
    end
    dp[0][0]
  end

  # --- pinned tie-break -----------------------------------------------------

  # Repeated lines make the placement ambiguous: going from "a\na\n" to
  # "a\na\na\n" the extra line can be first, second, or third and all are
  # minimal. Which one is chosen decides where a concurrent edit near the
  # repeats lands. This test PINS our choice so a future diff swap that changes
  # it fails loudly (it is a semantics change, not just an optimization).
  def test_tie_break_with_repeated_lines_is_pinned
    hunks = DbfsV2::Myers.hunks(%w[a a], %w[a a a])
    # Pinned: Myers appends at the END (the added token is the trailing one).
    assert_equal [[2, 2, 2, 3]], hunks
  end

  # --- scale: bounded AND correct -------------------------------------------

  # A small edit in a large file must stay minimal (two distinct hunks), and
  # fast. An O(n*m) table cannot run at this size, so this is not passable by
  # moving the old comparison-table cap around.
  def test_large_file_small_edit_is_bounded_and_minimal
    n = 20_000
    base = (0...n).map { |i| "line#{i}" }.join("\n")
    changed = base.sub("line1\n", "line1 CHANGED\n")
                  .sub("line#{n - 2}\n", "line#{n - 2} CHANGED\n")

    prims = Timeout.timeout(5) { DbfsV2::Transform.diff_prims(base, changed, 'p') }
    assert_equal 2, prims.size,
                 "expected 2 hunks; got #{prims.size}"
    assert_equal changed, apply(base, prims)
  end

  # A FULL rewrite (no common prefix or suffix) exceeds Myers' MAX_D, so the
  # diff intentionally degrades to one coarse hunk. It must still be bounded
  # (no O(n*m) blow-up) and still reconstruct exactly. This is the guard against
  # raising MAX_D to "fix" a large-file diff: the fallback is the point.
  def test_full_rewrite_of_large_file_is_bounded
    n = 20_000
    old = (0...n).map { |i| "line#{i}" }.join("\n")
    new = (0...n).map { |i| "LINE#{i}" }.join("\n")
    prims = Timeout.timeout(5) { DbfsV2::Transform.diff_prims(old, new, 'p') }
    assert_equal new, apply(old, prims)   # still correct, however coarse
  end
end
