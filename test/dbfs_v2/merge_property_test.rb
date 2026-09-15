# frozen_string_literal: true
#
# Three-way auto-merge, checked by content rather than by shape.
#
# Each side inserts uniquely named tokens ("<o.1>", "<t.3>") at random token
# boundaries and deletes random whole base tokens. A merge that reports success
# must contain every surviving base token and every inserted token exactly
# once, with no token split. (Merges that report a conflict are allowed; the
# line-hunk diff is coarse and conflicts often.) Before transform_list folded same-space prims
# right-to-left, a merged insert could land on the wrong line
# (test_insert_is_not_shifted_past_a_later_same_space_prim).
require_relative 'dbfs_v2_test_helper'

class MergePropertyTest < Minitest::Test
  include DbfsV2TestHelpers

  TOKEN = /<[a-z]\.\d+>/

  def ins(line, char, data) = DbfsV2::Delta.new('insertDataSingleLine', { startLine: line, startChar: char, data: data })

  # The regression that motivated this file, found by the client sync harness.
  def test_insert_is_not_shifted_past_a_later_same_space_prim
    s = setup_store
    s.create_file('/f', content: "a\nm\nb")
    s.branch('/f', 'b')
    s.write('/f', ins(0, 0, 'XXXX'))
    s.write('/f', ins(2, 0, 'Y'))
    s.write('/f', ins(0, 1, 'Z'), branch: 'b')
    res = s.merge('/f', target: 'main', source: 'b', auto: true)
    assert res[:merged]
    assert_equal "XXXXaZ\nm\nYb", res[:content]
  end

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
    ins(l, spots[rnd.rand(spots.length)], token)
  end

  def random_delete(text, rnd, deletable)
    candidates = deletable.select { |t| text.include?(t) }
    return nil if candidates.empty?

    tok = candidates[rnd.rand(candidates.length)]
    off = text.index(tok)
    buf = DbfsV2::Buffer.new(text)
    sl, sc = buf.position(off)
    el, ec = buf.position(off + tok.length)
    [tok, DbfsV2::Delta.new('deleteDataMultiLine', { startLine: sl, startChar: sc, endLine: el, endChar: ec })]
  end

  def test_random_token_merges_keep_every_token_exactly_once
    rnd = Random.new(Integer(ENV.fetch('MERGE_PROPERTY_SEED', '20260915')))
    s = setup_store
    merged = 0
    120.times do |t|
      path = "/p#{t}"
      base_tokens = (1..rnd.rand(0..6)).map { |i| "<b.#{i}>" }
      tail_tokens = (1..rnd.rand(0..4)).map { |i| "<c.#{i}>" }
      base = base_tokens.join + "\n" + tail_tokens.join
      s.create_file(path, content: base)
      s.branch(path, 'b')
      expected = base.scan(TOKEN)

      { 'main' => 'o', 'b' => 't' }.each do |branch, side|
        (1..rnd.rand(1..4)).each do |i|
          s.write(path, random_insert(s.read(path, branch: branch), rnd, "<#{side}.#{i}>"), branch: branch)
          expected << "<#{side}.#{i}>"
        end
        next unless rnd.rand < 0.5

        tok, del = random_delete(s.read(path, branch: branch), rnd, base.scan(TOKEN))
        next unless del

        s.write(path, del, branch: branch)
        expected.delete(tok) if expected.include?(tok)
      end

      res = s.merge(path, target: 'main', source: 'b', auto: true)
      next unless res[:merged]

      merged += 1
      assert_equal expected.tally, res[:content].scan(TOKEN).tally,
                   "case #{t}: base=#{base.inspect} merged=#{res[:content].inspect}"
      assert_equal res[:content].count('<'), res[:content].scan(TOKEN).size, "case #{t}: a token was split"
    end
    assert_operator merged, :>, 20, 'a fair share of random merges should be clean'
  end
end
