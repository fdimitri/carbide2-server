# frozen_string_literal: true
#
# Concurrent-edit integrity.
#
# Every test here guards one rule: a concurrent edit must never be silently
# lost, misapplied, or misreported. They came out of an external review, but the
# name describes what they protect, not where they came from:
#
#   * merge_conflicts? and merge_auto must AGREE (one diff-based definition of
#     conflict) — no spurious conflicts, no missed ones.
#   * a real conflict is reported as a conflict; an internal error is not.
#   * a write landing while a merge commits must not be clobbered (auto or
#     user-resolved).
#   * the in-memory cache must not be advanced past a foreign write.
#   * write() must validate against the edit's base, not a re-read head.
#
# The diff-scale tests that also came from the review live in diff_test.rb
# (test_large_file_small_edit_is_bounded_and_minimal, and the full-rewrite case).
#
# Design notes (why these tests are built the way they are):
#   * Hooks live HERE, in the test, and are prepended to the SINGLETON classes
#     of the module_function modules (Merge, Content). Nothing under lib/ or
#     config/ references them, so they cannot ship. rake test loads every test
#     file into one process, so they are active-but-inert for the whole suite.
#   * Every injection asserts `hook_fired`, so a test cannot pass because the
#     race it means to create silently never happened (the "zero assertions"
#     failure mode).
#   * The validation test hooks BOTH read paths the fix could use (head_cached
#     AND at); hooking only head_cached would let the natural fix validate
#     against Content#at, never trigger the injected write, and pass vacuously.
#
require_relative 'dbfs_v2_test_helper'

# Injection hooks, defined test-side only.
module DbfsV2
  module ReviewHooks
    class << self
      attr_accessor :after_auto_merge, :force_error, :on_read, :hook_fired

      def reset!
        self.after_auto_merge = nil
        self.force_error = nil
        self.on_read = nil
        self.hook_fired = false
      end

      # Fire the armed one-shot exactly once, marking that it fired.
      def fire!
        cb = @on_read
        return unless cb
        @on_read = nil
        self.hook_fired = true
        cb.call
      end
    end

    module MergeHook
      def auto_merge_content(*args, **kw)
        raise ReviewHooks.force_error if ReviewHooks.force_error
        result = super
        if ReviewHooks.after_auto_merge
          cb = ReviewHooks.after_auto_merge
          ReviewHooks.after_auto_merge = nil
          ReviewHooks.hook_fired = true
          cb.call
        end
        result
      end
    end

    # `Merge` and `Content` are module_function modules, so their methods are
    # singleton-class methods; the hook must be prepended there to take effect.
    module ReadHook
      %i[head_cached at].each do |m|
        define_method(m) do |*args, **kw|
          DbfsV2::ReviewHooks.fire!
          super(*args, **kw)
        end
      end
    end
  end
end
DbfsV2::Merge.singleton_class.prepend(DbfsV2::ReviewHooks::MergeHook)
DbfsV2::Content.singleton_class.prepend(DbfsV2::ReviewHooks::ReadHook)

class ConcurrentEditIntegrityTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
    DbfsV2::ReviewHooks.reset!
  end

  def teardown
    DbfsV2::ReviewHooks.reset!
  end

  def d(t, p) = DbfsV2::Delta.new(t, p)

  # --- merge conflict detection is one diff-based definition -----------------

  # A setContents that only changes line 0 and a replace on line 3 are disjoint
  # edits; they must not be reported as (or be) a conflict.
  def test_disjoint_setcontents_and_replace_do_not_conflict
    @s.create_file('/f', content: "line0\nline1\nline2\nline3\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('setContents', { data: "LINE0\nline1\nline2\nline3\n" }), branch: 'main')
    @s.write('/f', d('replaceDataSingleLine', { startLine: 3, startChar: 0, endChar: 5, data: 'LINE3' }), branch: 'feature')

    assert_equal [], @s.merge_conflicts?('/f', target: 'main', source: 'feature'),
                 'a disjoint setContents/replace pair must not be a conflict'
    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert res[:merged], 'disjoint setContents/replace should auto-merge'
    assert_equal "LINE0\nline1\nline2\nLINE3\n", res[:content]
  end

  # An insert inside a concurrent replace IS a conflict; merge_conflicts? must
  # say so AND merge_auto must agree (agreement on "clean" is not enough).
  def test_insert_inside_replace_conflicts_and_both_checkers_agree
    @s.create_file('/f', content: 'abcdef')
    @s.branch('/f', 'feature')
    @s.write('/f', d('replaceDataSingleLine', { startLine: 0, startChar: 1, endChar: 5, data: 'XYZ' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 3, data: 'Q' }), branch: 'feature')

    reported = @s.merge_conflicts?('/f', target: 'main', source: 'feature')
    refute_empty reported, 'insert inside a concurrent replace must be reported as a conflict'

    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)
    assert_equal 'conflict', res[:reason],
                 'merge_auto must agree with merge_conflicts? on the same heads'
  end

  # An internal bug must propagate; only a real ConflictError is a "conflict".
  def test_internal_merge_error_propagates_not_reported_as_conflict
    @s.create_file('/f', content: "base\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')

    DbfsV2::ReviewHooks.force_error = NoMethodError.new('boom from inside the merge')

    assert_raises(NoMethodError) do
      @s.merge('/f', target: 'main', source: 'feature', auto: true)
    end
  end

  # --- commit-time head re-check (no lost updates) ---------------------------

  # A write to the target landing after merge content is computed but before the
  # commit lock must not be clobbered by the merge commit.
  def test_auto_merge_does_not_clobber_concurrent_target_write
    @s.create_file('/f', content: "base\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')

    DbfsV2::ReviewHooks.after_auto_merge = lambda do
      @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'Z' }), branch: 'main')
    end

    res = @s.merge('/f', target: 'main', source: 'feature', auto: true)

    assert DbfsV2::ReviewHooks.hook_fired,
           'interleave was never injected; the test is vacuous'

    final = @s.read('/f')
    refute res[:merged] && !final.include?('Z'),
           "merge commit clobbered a concurrent write: merged=#{res[:merged]} final=#{final.inspect}"

    # If the merge DID commit, it must carry BOTH sides AND the interleaved
    # write. A fix that recomputes under the lock could keep Z and silently drop
    # m or f; checking only Z would pass that.
    if res[:merged]
      %w[m f Z].each do |c|
        assert_includes final, c, "merge dropped '#{c}': #{final.inspect}"
      end
    end
  end

  # The user-resolved path must refuse if the target advanced since the caller
  # resolved, instead of recording a merge that skipped the concurrent write.
  def test_user_resolved_merge_refuses_when_target_advanced
    @s.create_file('/f', content: "base\n")
    @s.branch('/f', 'feature')
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')

    resolved_against = Revision.where(file_node_id: @s.find('/f').id)
                               .joins(:branch).where(branches: { name: 'main' })
                               .order(:timestamp).last.id
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')
    before = Revision.where(file_node_id: @s.find('/f').id).count

    assert_raises(DbfsV2::ConflictError) do
      @s.merge('/f', target: 'main', source: 'feature', resolved: "base\nmf\n",
               expected_head: resolved_against)
    end
    assert_equal before, Revision.where(file_node_id: @s.find('/f').id).count,
                 'a refused merge must not add a revision'
  end

  # --- cache coherence -------------------------------------------------------

  # A nil cached head (empty base) must not be advanced past a foreign write.
  # Requires an explicit base so validation skips the cache refresh.
  def test_document_cache_does_not_advance_stale_nil_head
    f = @s.create_file('/f')          # empty: no head yet
    @s.read('/f')                     # seed cache entry with head_id == nil

    rev = Revision.create!(
      file_node_id: f.id, parent_id: nil, branch_id: f.branches.first.id,
      change_type: 'setContents', change_data: { data: 'FOREIGN' }.to_json,
      timestamp: Time.now.utc
    )
    f.branches.first.update!(head_revision_id: rev.id)

    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'L' }), base_revision_id: rev.id)

    assert_equal 'LFOREIGN', @s.read('/f'),
                 'cache advanced a stale (nil-head) buffer and dropped/misplaced the foreign content'
  end

  # --- write validation base -------------------------------------------------

  # write() must validate against the edit's base, not a head re-read mid-write.
  # Hooks BOTH read paths so the race fires under either implementation.
  def test_write_validates_against_base_not_reread_head
    @s.create_file('/f', content: 'abc')   # head H1, single line

    DbfsV2::ReviewHooks.on_read = lambda do
      @s.write('/f', d('insertDataMultiLine', { startLine: 0, startChar: 3, data: "\nXY" }))
    end

    outcome =
      begin
        @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'Z' }))
        :accepted
      rescue ArgumentError
        :refused
      end

    assert DbfsV2::ReviewHooks.hook_fired,
           'race was never injected; test is vacuous'

    if outcome == :accepted
      assert_equal "abc\nZXY", @s.read('/f'),
                   'edit was accepted against the re-read head and landed at the wrong offset'
    else
      assert_equal :refused, outcome
    end
  end
end
