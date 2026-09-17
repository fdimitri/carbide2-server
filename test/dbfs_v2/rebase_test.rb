# frozen_string_literal: true
#
# DbfsV2::Rebase — a sequence of edits authored against an older revision,
# transformed onto the head one edit at a time.
#
# Checked by content: both sides insert uniquely named tokens at token
# boundaries and delete whole tokens; after the rebase the head holds every
# token that was inserted and not deleted by either side, exactly once and
# unsplit, and the bridge takes the author's state to that head.
require_relative 'dbfs_v2_test_helper'

class RebaseTest < Minitest::Test
  include StoreTestHelpers

  TOKEN = /<[a-z]\d*\.\d+>/

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })

  def main_head(s, path) = head(s, path)

  def apply_hashes(text, hashes)
    buf = DbfsV2::Buffer.new(text)
    hashes.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k, _| k == :type }).apply_to(buf) }
    buf.to_s
  end

  def test_rebases_edits_past_concurrent_ones_and_records_the_bridge
    s = setup_store
    s.create_file('/f', content: "one\ntwo\n")
    base = main_head(s, '/f')
    s.write('/f', ins(0, 0, 'X'))
    authored = [ins(1, 3, '!'), ins(1, 4, '?')]
    local = DbfsV2::Buffer.new("one\ntwo\n")
    authored.each { |a| a.apply_to(local) }

    res = DbfsV2::Rebase.onto!(s, s.find('/f'), authored.map { |a| d(a.type, a.payload) },
                               base_id: base, source_head_id: nil)
    assert_equal "Xone\ntwo!?\n", s.read('/f')
    assert_equal s.read('/f'), apply_hashes(local.to_s, res[:bridge])
    assert_equal res[:head], main_head(s, '/f')
  end

  def test_overlap_with_a_concurrent_replace_is_refused_and_commits_nothing
    s = setup_store
    s.create_file('/f', content: "abcdef\n")
    base = main_head(s, '/f')
    s.write('/f', d('replaceDataSingleLine', { startLine: 0, startChar: 1, endChar: 4, data: 'XYZ' }))
    before = main_head(s, '/f')
    assert_raises(DbfsV2::ConflictError) do
      DbfsV2::Rebase.onto!(s, s.find('/f'), [ins(0, 2, 'q')], base_id: base, source_head_id: nil)
    end
    assert_equal before, main_head(s, '/f')
  end

  def test_unknown_base_is_refused
    s = setup_store
    s.create_file('/f', content: "a\n")
    assert_nil DbfsV2::Rebase.concurrent_since(s.find('/f'), SecureRandom.uuid, main_head(s, '/f'))
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

  def random_edit(text, rnd, token, deletable)
    if rnd.rand < 0.35
      present = deletable.select { |t| text.include?(t) }
      unless present.empty?
        tok = present[rnd.rand(present.length)]
        buf = DbfsV2::Buffer.new(text)
        off = text.index(tok)
        sl, sc = buf.position(off)
        el, ec = buf.position(off + tok.length)
        return [:delete, tok, d('deleteDataMultiLine', { startLine: sl, startChar: sc, endLine: el, endChar: ec })]
      end
    end
    lines = text.split("\n", -1)
    l = rnd.rand(lines.length)
    spots = boundaries(lines[l])
    data = rnd.rand < 0.2 ? "#{token}\n" : token
    [:insert, token, d(data.include?("\n") ? 'insertDataMultiLine' : 'insertDataSingleLine',
                      { startLine: l, startChar: spots[rnd.rand(spots.length)], data: data })]
  end

  # Author and others edit concurrently for several rounds; each round the
  # author rebases a batch based on its OWN previous state (the source head of
  # its previous rebase), which exercises the bridge.
  def test_random_rounds_keep_every_token_exactly_once
    rnd = Random.new(Integer(ENV.fetch('REBASE_PROPERTY_SEED', '915')))
    30.times do |run|
      s = setup_store
      path = '/f'
      initial = (1..rnd.rand(0..5)).map { |i| "<b.#{i}>" }.join + "\n" + (1..rnd.rand(0..3)).map { |i| "<c.#{i}>" }.join
      s.create_file(path, content: initial)
      node = s.find(path)
      alive = initial.scan(TOKEN)
      author_base = main_head(s, path)
      author_view = initial
      refused = 0

      6.times do |round|
        # others edit main
        rnd.rand(0..3).times do |k|
          kind, tok, delta = random_edit(s.read(path), rnd, "<o#{round}.#{k}>", alive)
          s.write(path, delta)
          kind == :insert ? alive << tok : alive.delete(tok)
        end
        # the author edits its own view, then rebases the batch
        batch = []
        local_alive = alive.dup
        view = author_view
        rnd.rand(1..3).times do |k|
          kind, tok, delta = random_edit(view, rnd, "<a#{round}.#{k}>", author_view.scan(TOKEN))
          batch << [kind, tok, delta]
          buf = DbfsV2::Buffer.new(view)
          delta.apply_to(buf)
          view = buf.to_s
        end
        # As ProjectFs does: the batch as authored goes on a branch forked at
        # the author's base; its head is the author's state.
        bname = "a#{run}.#{round}"
        s.branch(path, bname, at_revision: author_base)
        batch.each { |_, _, x| s.write(path, d(x.type, x.payload), branch: bname) }
        source_head = node.branches.find_by!(name: bname).head_revision_id
        assert_equal view, s.read(path, revision_id: source_head)
        begin
          res = DbfsV2::Rebase.onto!(s, node, batch.map { |_, _, x| d(x.type, x.payload) },
                                     base_id: author_base, source_head_id: source_head)
        rescue DbfsV2::ConflictError
          refused += 1
          author_view = s.read(path)
          author_base = main_head(s, path)
          next
        end
        batch.each { |kind, tok, _| kind == :insert ? local_alive << tok : local_alive.delete(tok) }
        alive = local_alive
        head = s.read(path)
        assert_equal head, apply_hashes(view, res[:bridge]), "run #{run} round #{round}: bridge does not reach the head"
        # The author keeps going from its own state: the next batch is based on
        # the branch head, reachable only through the recorded bridge.
        author_view = view
        author_base = source_head
        assert_equal alive.tally, head.scan(TOKEN).tally, "run #{run} round #{round}: tokens lost or duplicated in #{head.inspect}"
        assert_equal head.count('<'), head.scan(TOKEN).size, "run #{run} round #{round}: a token was split in #{head.inspect}"
      end
      assert_operator refused, :<, 6, "run #{run}: every round conflicted"
    end
  end
end
