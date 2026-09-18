# frozen_string_literal: true
module DbfsV2
  # Diff3 — a line-based three-way merge for a human to finish.
  #
  # Not the auto-merge (that is Merge.auto_merge_content, OT prims at the DAG
  # base, and it refuses overlapping writes). This is what the merge tab shows
  # once auto-merge has refused: base vs ours and base vs theirs hunked by line
  # (Myers), walked together; regions only one side changed take that side,
  # regions both sides changed identically take it once, and the rest become
  # conflict blocks with markers. The blocks are also returned as line ranges
  # in the output so a UI can decorate and step through them.
  module Diff3
    module_function

    Block = Struct.new(:start_line, :end_line, :ours, :theirs, :base, keyword_init: true)

    # Returns { text:, conflicts: n, blocks: [Block] }. Lines are 0-based,
    # end exclusive, in the returned text's coordinates (markers included).
    def merge(base, ours, theirs, labels: %w[ours theirs])
      b = Transform.diff_tokens(base.to_s)
      o = Transform.diff_tokens(ours.to_s)
      t = Transform.diff_tokens(theirs.to_s)
      b = [] if base.to_s.empty?
      o = [] if ours.to_s.empty?
      t = [] if theirs.to_s.empty?

      ho = Transform.diff_hunks(b, o)   # [[bs, be, ns, ne]] in base / ours coords
      ht = Transform.diff_hunks(b, t)

      out    = []
      blocks = []
      i = 0
      io = it = 0
      loop do
        nxt = [ho[io]&.first, ht[it]&.first].compact.min
        break if nxt.nil?
        out.concat(b[i...nxt]) if nxt > i
        start = nxt
        fin   = start
        ours_h, theirs_h = [], []
        # Grow the region while either side has a hunk overlapping or touching
        # it (conservative: adjacent edits by both sides conflict, as in git).
        loop do
          grew = false
          while (h = ho[io]) && h[0] <= fin
            ours_h << h; fin = [fin, h[1]].max; io += 1; grew = true
          end
          while (h = ht[it]) && h[0] <= fin
            theirs_h << h; fin = [fin, h[1]].max; it += 1; grew = true
          end
          break unless grew
        end
        o_text = side_text(b, o, ours_h,   start, fin)
        t_text = side_text(b, t, theirs_h, start, fin)
        if ours_h.empty? || theirs_h.empty? || o_text == t_text
          out.concat(ours_h.empty? ? t_text : o_text)
        else
          base_text = b[start...fin]
          from = out.length
          out << "<<<<<<< #{labels[0]}\n"
          out.concat(ensure_nl(o_text))
          out << "=======\n"
          out.concat(ensure_nl(t_text))
          out << ">>>>>>> #{labels[1]}\n"
          blocks << Block.new(start_line: from, end_line: out.length,
                              ours: o_text.join, theirs: t_text.join, base: base_text.join)
        end
        i = fin
      end
      out.concat(b[i..]) if i < b.length
      { text: out.join, conflicts: blocks.size, blocks: blocks }
    end

    class << self
      private

      # The side's lines for base region [start, fin): base lines up to the
      # first hunk, the side's own lines across the hunks (including unchanged
      # lines between them), base lines after the last hunk.
      def side_text(b, side, hunks, start, fin)
        return b[start...fin] if hunks.empty?
        first, last = hunks.first, hunks.last
        b[start...first[0]] + side[first[2]...last[3]] + b[last[1]...fin]
      end

      # A final line without "\n" would swallow the following marker.
      def ensure_nl(lines)
        return lines if lines.empty? || lines.last.end_with?("\n")
        lines[0...-1] + [lines.last + "\n"]
      end
    end
  end
end
