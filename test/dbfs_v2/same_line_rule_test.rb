# frozen_string_literal: true
#
# The same-line rule (decisions #29).
#
# A whole-file snapshot (a setContents: an external change the watcher absorbs,
# an agent's full-file write, a merge with no edit history) says nothing about
# what was edited, so the server diffs it. A diff is a guess and can line up
# differently from what happened; refined into minimal splices, two changes on
# one line could be combined into garbled text and reported clean. So a snapshot
# claims the whole lines its diff changes, and any other change touching one of
# those lines conflicts. Branch merges replay the branch's real edits instead of
# diffing, so edits on the same line of two branches still merge.
#
# The two garbling cases here were found by the client OT port's merge property
# test: '<b.1><b.2>' merged to '<o.2>', and a moved blank line produced
# '<c.o.1><3>'.
require_relative 'dbfs_v2_test_helper'

class SameLineRuleTest < Minitest::Test
  include StoreTestHelpers

  T = DbfsV2::Transform
  TOKEN = /<[a-z]\d*\.\d+>/

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })

  # --- the diff ------------------------------------------------------------

  def test_snapshot_diff_claims_whole_lines
    rewrite = T.diff_prims("a\nbXc\nd", "a\nbYc\nd", 'p')
    assert_equal [[2, 6, "bYc\n", 'p', :lines]], rewrite.map(&:to_a)

    last = T.diff_prims("a\nb", "a\nbc", 'p')
    assert_equal [[2, 3, 'bc', 'p', :lines_eof]], last.map(&:to_a)

    added = T.diff_prims("a\nb", "a\nnew\nb", 'p')
    assert_equal [[2, 2, "new\n", 'p', :before]], added.map(&:to_a)
  end

  def test_claimed_lines_conflict_with_changes_on_them_only
    base = "one\ntwo\nthree"
    snap = T.diff_prims(base, "one\nTWO\nthree", 's')         # claims line 1 [4, 8)
    at = ->(o, text = 'x') { [T::Prim.new(o, o, text, 'e')] }
    del = ->(s, f) { [T::Prim.new(s, f, '', 'e')] }

    assert T.ambiguous?(snap, at.call(5)), 'insert inside the claimed line'
    assert T.ambiguous?(snap, at.call(4)), 'insert at the start of the claimed line'
    assert T.ambiguous?(snap, del.call(2, 5)), 'delete reaching into the claimed line'
    assert T.ambiguous?(at.call(6), snap), 'symmetric'
    refute T.ambiguous?(snap, at.call(8)), 'insert at the start of the next line'
    refute T.ambiguous?(snap, at.call(3)), 'insert at the end of the previous line'
    refute T.ambiguous?(snap, at.call(4, "new\n")), 'a whole line added before the claimed line'
    refute T.ambiguous?(snap, del.call(9, 12)), 'delete on another line'
  end

  def test_added_lines_go_before_a_plain_insert_at_the_same_point
    base = "a\nb"
    added = T.diff_prims(base, "a\nnew\nb", 's')              # insert "new\n" at 2, :before
    typed = [T::Prim.new(2, 2, 'X', 'a')]                     # typed at the start of "b"
    [[added, typed], [typed, added]].each do |first, second|
      buf = DbfsV2::Buffer.new(base)
      DbfsV2::Merge.apply_prims(buf, first)
      DbfsV2::Merge.apply_prims(buf, T.transform_list(second, first))
      assert_equal "a\nnew\nXb", buf.to_s
    end
  end

  # --- the two garbling cases ------------------------------------------------

  def test_content_merge_of_rename_and_delete_on_one_line_conflicts
    base = "<b.1><b.2><b.3>\n<c.1>"
    ours = T.diff_prims(base, "<o.1><b.2><b.3>\n<c.1>", 'ours')
    theirs = T.diff_prims(base, "<b.2><b.3>\n<c.1>", 'theirs')
    assert T.ambiguous?(ours, theirs)
  end

  def test_content_merge_with_a_moved_blank_line_conflicts
    base = "\n<c.1><c.2><c.3>"
    ours = T.diff_prims(base, "\n<c.1><c.2><o.1><c.3>", 'ours')
    theirs = T.diff_prims(base, "<t.2>\n<c.1><c.2><t.1><t.3>\n\n<c.3>", 'theirs')
    assert T.ambiguous?(ours, theirs)
  end

  # The live path: typing on a line while an external tool rewrites it.
  def test_edit_on_a_line_an_external_rewrite_changed_conflicts
    s = setup_store
    s.create_file('/f', content: "\n<c.1><c.2><c.3>")
    base = head(s, '/f')
    s.write('/f', d('setContents', { data: "<t.2>\n<c.1><c.2><t.1><t.3>\n\n<c.3>" }))
    before = head(s, '/f')
    assert_raises(DbfsV2::ConflictError) { s.write('/f', ins(1, 10, '<o.1>'), base_revision_id: base) }
    assert_equal before, head(s, '/f')
    assert_raises(DbfsV2::ConflictError) do
      DbfsV2::Rebase.compute("\n<c.1><c.2><c.3>", [ins(1, 10, '<o.1>')],
                             [d('setContents', { data: "<t.2>\n<c.1><c.2><t.1><t.3>\n\n<c.3>" }).tap { |x| x.priority = 'r' }])
    end
  end

  def test_edit_on_another_line_than_an_external_rewrite_merges
    s = setup_store
    s.create_file('/f', content: "one\ntwo\nthree\n")
    base = head(s, '/f')
    s.write('/f', d('setContents', { data: "one\nTWO\nthree\n" }))
    s.write('/f', ins(2, 5, '!'), base_revision_id: base)
    s.write('/f', ins(0, 0, '>'), base_revision_id: base)
    assert_equal ">one\nTWO\nthree!\n", s.read('/f')
  end

  # --- merges replay edits ----------------------------------------------------

  def test_branch_edits_on_one_line_still_merge
    s = setup_store
    s.create_file('/f', content: "<b.1><b.2><b.3>\n<c.1>")
    s.branch('/f', 'feat')
    s.write('/f', ins(0, 0, '<o.1>'))
    s.write('/f', d('deleteDataSingleLine', { startLine: 0, startChar: 5, endChar: 10 }))  # main: rename b.1 -> o.1
    s.write('/f', d('deleteDataSingleLine', { startLine: 0, startChar: 0, endChar: 5 }), branch: 'feat') # feat: delete b.1
    assert_equal [], s.merge_conflicts?('/f', target: 'main', source: 'feat')
    res = s.merge('/f', target: 'main', source: 'feat', auto: true)
    assert res[:merged], res.inspect
    assert res[:replayed]
    assert_equal "<o.1><b.2><b.3>\n<c.1>", s.read('/f')
  end

  def test_a_snapshot_on_a_branch_is_held_to_the_same_line_rule_when_replayed
    s = setup_store
    s.create_file('/f', content: "one\ntwo\nthree")
    s.branch('/f', 'feat')
    s.write('/f', ins(1, 1, 'X'))
    s.write('/f', d('setContents', { data: "one\nTWO\nthree" }), branch: 'feat')
    confs = s.merge_conflicts?('/f', target: 'main', source: 'feat')
    refute_empty confs
    res = s.merge('/f', target: 'main', source: 'feat', auto: true)
    refute res[:merged]
    assert_equal confs, res[:conflicts]
    assert_equal "one\ntXwo\nthree", s.read('/f')

    s2 = setup_store
    s2.create_file('/g', content: "one\ntwo\nthree")
    s2.branch('/g', 'feat')
    s2.write('/g', ins(2, 5, '!'))
    s2.write('/g', d('setContents', { data: "one\nTWO\nthree" }), branch: 'feat')
    assert s2.merge('/g', target: 'main', source: 'feat', auto: true)[:merged]
    assert_equal "one\nTWO\nthree!", s2.read('/g')
  end

  # A source that merged the target in has no first-parent path from the merge
  # base, so there is nothing to replay: the content merge runs, under the
  # same-line rule.
  def test_content_merge_fallback_applies_the_same_line_rule
    s = setup_store
    s.create_file('/f', content: "a\nb\nc\n")
    s.branch('/f', 'feat')
    s.write('/f', ins(0, 1, '1'))
    s.write('/f', ins(2, 1, '2'), branch: 'feat')
    assert s.merge('/f', target: 'feat', source: 'main', auto: true)[:merged]   # feat takes main
    s.write('/f', ins(1, 1, 'M'))                                              # main: line b
    s.write('/f', ins(1, 0, 'F'), branch: 'feat')                              # feat: line b too

    node = s.find('/f')
    t = head(s, '/f')
    f = head(s, '/f', 'feat')
    assert_nil DbfsV2::Merge.replay_plan(node, t, f), 'expected no replayable history'
    res = s.merge('/f', target: 'main', source: 'feat', auto: true)
    refute res[:merged], "same-line content merge must conflict: #{res.inspect}"

    s.write('/f', d('deleteDataSingleLine', { startLine: 1, startChar: 0, endChar: 1 }), branch: 'feat')
    s.write('/f', ins(3, 0, 'z'), branch: 'feat')
    res = s.merge('/f', target: 'main', source: 'feat', auto: true)
    assert res[:merged], res.inspect
    refute res[:replayed]
    assert_equal "a1\nbM\nc2\nz", s.read('/f')
  end

  # --- properties ---------------------------------------------------------------

  def boundaries(line)
    out = []
    depth = 0
    (0..line.length).each do |i|
      out << i if depth.zero?
      depth += 1 if line[i] == '<'
      depth = [depth - 1, 0].max if line[i] == '>'
    end
    out
  end

  def random_insert(text, rnd, token)
    lines = text.split("\n", -1)
    l = rnd.rand(lines.length)
    spots = boundaries(lines[l])
    data = rnd.rand < 0.2 ? "#{token}\n" : token
    [d(data.include?("\n") ? 'insertDataMultiLine' : 'insertDataSingleLine', { startLine: l, startChar: spots[rnd.rand(spots.length)], data: data }),
     token]
  end

  def random_delete(text, rnd, deletable)
    present = deletable.select { |t| text.include?(t) }
    return nil if present.empty?

    tok = present[rnd.rand(present.length)]
    buf = DbfsV2::Buffer.new(text)
    off = text.index(tok)
    sl, sc = buf.position(off)
    el, ec = buf.position(off + tok.length)
    [d('deleteDataMultiLine', { startLine: sl, startChar: sc, endLine: el, endChar: ec }), tok]
  end

  def edit_side(text, rnd, side, base_tokens, expected, snapshot:)
    edits = []
    (1..rnd.rand(1..4)).each do |i|
      delta, tok = random_insert(text, rnd, "<#{side}.#{i}>")
      text = delta.apply_to(DbfsV2::Buffer.new(text)).to_s
      edits << delta
      expected << tok
    end
    if rnd.rand < 0.5 && (del = random_delete(text, rnd, base_tokens))
      delta, tok = del
      text = delta.apply_to(DbfsV2::Buffer.new(text)).to_s
      edits << delta
      expected.delete_at(expected.index(tok)) if expected.include?(tok)
    end
    snapshot ? [d('setContents', { data: text })] : edits
  end

  # Clean merges keep every surviving token exactly once, unsplit, whether the
  # branches hold real edits (replayed) or snapshots (diffed, same-line rule),
  # and whether the merge replays or falls back to the content merge.
  def test_random_branch_merges_never_garble
    rnd = Random.new(Integer(ENV.fetch('SAME_LINE_SEED', '29')))
    s = setup_store
    counts = Hash.new(0)
    160.times do |t|
      path = "/p#{t}"
      base = (0..rnd.rand(1..5)).map { |l| (1..rnd.rand(0..3)).map { |i| "<b#{l}.#{i}>" }.join }.join("\n")
      s.create_file(path, content: base)
      s.branch(path, 'feat')
      base_tokens = base.scan(TOKEN)
      expected = base_tokens.dup
      mode = %i[edits snap_main snap_feat].sample(random: rnd)
      edit_side(base, rnd, 'o', base_tokens, expected, snapshot: mode == :snap_main).each { |x| s.write(path, x) }
      edit_side(base, rnd, 't', base_tokens, expected, snapshot: mode == :snap_feat).each { |x| s.write(path, x, branch: 'feat') }
      # Both sides may delete the same base token; expected removed it once.
      res = s.merge(path, target: 'main', source: 'feat', auto: true)
      counts[[mode, res[:merged] ? :merged : :conflict]] += 1
      next unless res[:merged]

      out = s.read(path)
      assert_equal expected.tally, out.scan(TOKEN).tally, "case #{t} (#{mode}): #{base.inspect} -> #{out.inspect}"
      assert_equal out.count('<'), out.scan(TOKEN).size, "case #{t} (#{mode}): split token in #{out.inspect}"
    end
    assert_operator counts[[:edits, :merged]], :>, 30, counts.inspect
    assert_operator counts[[:snap_main, :merged]] + counts[[:snap_feat, :merged]], :>, 10, counts.inspect
  end
end
