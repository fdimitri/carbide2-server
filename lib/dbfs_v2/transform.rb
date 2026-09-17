# frozen_string_literal: true
require_relative 'myers'

module DbfsV2
  module Transform
    # `claim` marks a prim taken from a diff of a whole-file snapshot
    # (setContents, a merge with no history to replay); real edits have none.
    #   :lines      it rewrites or removes whole lines, each ending in a newline;
    #               any other change touching one of them is ambiguous
    #   :lines_eof  the same, for lines running to the end of the text
    #   :before     it only adds whole lines at a line start; it touches no
    #               existing line, and goes before any other same-point insert
    #               (a plain insert there meant the start of the old line)
    # See decisions #29.
    Prim = Struct.new(:start, :finish, :text, :priority, :claim) do
      def insert?  = start == finish
      def delete?  = start < finish && text.empty?
      def replace? = start < finish && !text.empty?
      def length   = finish - start
      def ilength  = text.length
    end

    module_function

    def transform(a, b, base)
      # Opaque ops (regex replace, full-content reset) are content-addressed and
      # not composable piecewise; route them to the convergent snapshot path.
      # setContents is a full-document reset, so concurrent with anything it is
      # a clobber, not a merge.
      return transform_opaque(a, b, base) if opaque?(a) || opaque?(b)

      a_prims = to_prims(a, base)
      b_prims = to_prims(b, base)

      # Overlapping write-vs-replace is genuinely ambiguous; fall back to a
      # convergent snapshot. Non-overlapping stays precise.
      if ambiguous?(a_prims, b_prims)
        return transform_opaque(a, b, base)
      end

      a_prime = transform_list(a_prims, b_prims)
      b_prime = transform_list(b_prims, a_prims)
      [encode(a_prime, base, b), encode(b_prime, base, a)]
    end

    def opaque?(delta)
      delta.pcre_replace?
    end

    # Diff old -> new into prims, one per LINE hunk (Myers over lines tokenized
    # WITH their trailing newline, so each hunk is an exact flat char range).
    # Used so a setContents, or a merge that has no edit history to replay, can
    # be treated as "these are my changes" and merged with concurrent edits.
    #
    # A diff only guesses what was edited, and the guess can line up differently
    # from what happened, so its changes are not refined to minimal splices: a
    # hunk that rewrites or removes lines is one prim over those whole lines,
    # with a claim on them (see Prim). Two changes on the same line then conflict
    # instead of being spliced into garbled text (decisions #29). A hunk that
    # only adds lines between existing ones is a plain insert: it touches no
    # existing line.
    def diff_prims(old, new, pri)
      return [] if old == new
      old_t = diff_tokens(old)
      new_t = diff_tokens(new)
      hunks = diff_hunks(old_t, new_t)
      offs = [0]
      old_t.each { |t| offs << (offs.last + t.length) }
      hunks.filter_map do |os, oe, ns, ne|
        start  = offs[os]
        finish = offs[oe]
        text   = new_t[ns...ne].join
        next if start == finish && text.empty?
        next Prim.new(start, finish, text, pri, :before) if os == oe

        eof = oe == old_t.length && !old_t.last.end_with?("\n")
        Prim.new(start, finish, text, pri, eof ? :lines_eof : :lines)
      end
    end

    # Lines including their trailing newline (the last line may have none), so
    # concatenating the tokens reproduces the string exactly.
    # The empty string is one empty line, as in Buffer.
    def diff_tokens(str)
      return [''] if str.empty?

      lines = str.split("\n", -1)
      lines.each_with_index.map { |l, i| i < lines.length - 1 ? l + "\n" : l }
    end

    # Hunks over token arrays, each [old_start, old_end, new_start, new_end].
    # Myers O(ND) (DbfsV2::Myers) — minimal and fast for realistic edits, rather
    # than the old O(n*m) LCS table that went quadratic (and then fell back to a
    # single whole-file hunk) on large files. When the edit distance is huge
    # (a genuine full rewrite) Myers returns nil and we fall back to one coarse
    # hunk, which is correct and, for a full rewrite, exactly right.
    def diff_hunks(a, b)
      Myers.hunks(a, b) || diff_hunks_fallback(a, b)
    end

    # Single hunk: common token prefix + common token suffix, changed middle as
    # one replace. Used for very large inputs.
    def diff_hunks_fallback(a, b)
      n = a.length
      m = b.length
      p = 0
      p += 1 while p < n && p < m && a[p] == b[p]
      s = 0
      s += 1 while s < (n - p) && s < (m - p) && a[n - 1 - s] == b[m - 1 - s]
      [[p, n - s, p, m - s]]
    end

    # True when a replace primitive overlaps another primitive's region, an
    # insert falls inside a replace's region (insert-inside-replace), or either
    # side touches a line the other side's snapshot diff claimed.
    def ambiguous?(a_prims, b_prims)
      a_prims.any? { |ap| ap.replace? && b_prims.any? { |bp| regions_overlap?(ap, bp) } } ||
        b_prims.any? { |bp| bp.replace? && a_prims.any? { |ap| regions_overlap?(ap, bp) } } ||
        a_prims.any? { |ap| b_prims.any? { |bp| touches_claim?(ap, bp) || touches_claim?(bp, ap) } }
    end

    # Does `o` change a line that claimed prim `c` rewrites? c covers whole
    # lines [c.start, c.finish); a newline belongs to the line it ends.
    #   * a delete/replace touches them if its range intersects;
    #   * an insert touches them if it lands inside, at the start of the first
    #     line (unless it only adds whole lines before it: text ending in a
    #     newline), or at the very end when the claim runs to end of text.
    def touches_claim?(c, o)
      return false unless %i[lines lines_eof].include?(c.claim)

      if o.insert?
        p = o.start
        return true if c.start < p && p < c.finish
        return true if p == c.finish && c.claim == :lines_eof
        p == c.start && !o.text.end_with?("\n")
      else
        o.start < c.finish && c.start < o.finish
      end
    end

    def regions_overlap?(x, y)
      return false if x.insert? && y.insert?
      # An op's "region" is [start, finish) for delete/replace; for insert it's a point.
      xs = x.start
      xe = x.insert? ? x.start : x.finish
      ys = y.start
      ye = y.insert? ? y.start : y.finish
      # overlap if intervals [xs,xe) and [ys,ye) intersect, treating point-inside-region as overlap
      xs < ye && ys < xe
    end

    # Convergent snapshot for opaque ops. Order-INDEPENDENT: the two ops are
    # applied in a deterministic order (by priority, tie-broken by content), so
    # transform(a,b) and transform(b,a) produce the SAME merged document. Both
    # a_prime and b_prime are that snapshot, so either application order
    # converges on it.
    def transform_opaque(a, b, base)
      ordered = [a, b].sort_by { |d| [d.priority.to_s, d.type, d.payload.to_json] }
      merged = Buffer.new(base.to_s)
      ordered.each { |d| d.apply_to(merged) }
      sc = { type: 'setContents', data: merged.to_s }
      [[sc], [sc]]
    end

    # Transform each of `ops` past all of `others`. Both lists are SAME-SPACE
    # (every prim in a list is in the one base coordinate space, as diff_prims,
    # to_prims and apply_prims use them), so `others` cannot be folded in list
    # order: after the first transform the op is in base+other1 space while
    # other2 is still in base space, and an op right of other1 gets compared
    # against other2 at the wrong offset (an insert could land on the wrong
    # line). Folded right-to-left (descending start, original order on ties) the
    # same-space list IS a valid chained sequence — each prim only shifts
    # offsets beyond itself — which is exactly how apply_prims/deltas_for apply
    # them, so each step compares like with like.
    def transform_list(ops, others)
      chained = others.each_with_index.sort_by { |o, i| [-o.start, i] }.map(&:first)
      ops.flat_map do |op|
        chained.reduce([op]) do |acc, other|
          # A prim keeps its claim wherever it moves (ambiguous? has already
          # refused anything that would cut into a claimed region).
          acc.flat_map { |o| transform_one(o, other).each { |t| t.claim = o.claim } }
        end
      end
    end

    def encode(prims, base, applied)
      buf = Buffer.new(base.to_s)
      applied.apply_to(buf)
      deltas_for(prims, buf)
    end

    # Emit deltas for a prim list that is all in `buf`'s coordinate space.
    # Apply right-to-left (descending start) so each prim's coords stay valid;
    # the emitted sequence is a valid chained patch for the caller.
    def deltas_for(prims, buf)
      prims.each_with_index.sort_by { |p, i| [-p.start, i] }.map(&:first).map do |p|
        d = to_delta(p, buf)
        Delta.new(d[:type], d.reject { |k, _| k == :type }).apply_to(buf)
        d
      end
    end

    def transform_one(a, b)
      if a.insert? && b.insert?
        transform_ii(a, b)
      elsif a.insert? && b.delete?
        transform_id(a, b)
      elsif a.insert? && b.replace?
        transform_ir(a, b)
      elsif a.delete? && b.insert?
        transform_di(a, b)
      elsif a.delete? && b.delete?
        transform_dd(a, b)
      elsif a.delete? && b.replace?
        transform_dr(a, b)
      elsif a.replace? && b.insert?
        transform_ri(a, b)
      elsif a.replace? && b.delete?
        transform_rd(a, b)
      elsif a.replace? && b.replace?
        transform_rr(a, b)
      else
        [a]
      end
    end

    def transform_ii(a, b)
      if a.start < b.start || (a.start == b.start && insert_first?(a, b))
        [a]
      else
        [Prim.new(a.start + b.ilength, a.finish + b.ilength, a.text, a.priority)]
      end
    end

    # At a tie, a snapshot's added lines go before a plain insert (which meant
    # the start of the existing line); otherwise priority decides.
    def insert_first?(a, b)
      a_lines = a.claim == :before && !(b.claim == :before)
      b_lines = b.claim == :before && !(a.claim == :before)
      return true if a_lines
      return false if b_lines

      a.priority <= b.priority
    end

    def transform_id(a, b)
      if a.start <= b.start
        [a]
      elsif a.start >= b.finish
        [Prim.new(a.start - b.length, a.finish - b.length, a.text, a.priority)]
      else
        [Prim.new(b.start, b.start, a.text, a.priority)]
      end
    end

    # insert a vs replace b
    def transform_ir(a, b)
      if a.start <= b.start
        [a]
      elsif a.start >= b.finish
        [Prim.new(a.start + (b.ilength - b.length), a.finish + (b.ilength - b.length), a.text, a.priority)]
      else
        [Prim.new(b.start, b.start, a.text, a.priority)]
      end
    end

    def transform_di(a, b)
      if b.start <= a.start
        [Prim.new(a.start + b.ilength, a.finish + b.ilength, a.text, a.priority)]
      elsif b.start >= a.finish
        [a]
      else
        # Insert inside the deleted range: split the delete AROUND the insert
        # so the insert survives. Both pieces are in the SAME (post-b) space,
        # applied right-to-left — not chained.
        first  = Prim.new(a.start, b.start, '', a.priority)
        second = Prim.new(b.start + b.ilength, a.finish + b.ilength, '', a.priority)
        [first, second]
      end
    end

    def transform_dd(a, b)
      if b.finish <= a.start
        [Prim.new(a.start - b.length, a.finish - b.length, '', a.priority)]
      elsif b.start >= a.finish
        [a]
      else
        out = []
        has_left  = a.start < b.start
        has_right = a.finish > b.finish
        out << Prim.new(a.start, b.start, '', a.priority) if has_left
        # Right remnant is in post-b space (b removed [b.start,b.finish)).
        out << Prim.new(b.start, b.start + (a.finish - b.finish), '', a.priority) if has_right
        out
      end
    end

    # delete a vs replace b
    def transform_dr(a, b)
      if a.finish <= b.start
        [a]
      elsif a.start >= b.finish
        [Prim.new(a.start - (b.length - b.ilength), a.finish - (b.length - b.ilength), '', a.priority)]
      else
        # Remnants in post-b space (b replaced [b.start,b.finish) with ilength
        # chars). Left of b unchanged; right of b shifts by ilength-b.length...
        # both expressed in the SAME post-b space.
        out = []
        out << Prim.new(a.start, b.start, '', a.priority) if a.start < b.start
        if a.finish > b.finish
          out << Prim.new(b.start + b.ilength, b.start + b.ilength + (a.finish - b.finish), '', a.priority)
        end
        out
      end
    end

    # replace a vs insert b. Overlap (strictly inside) is routed to the opaque
    # path by #ambiguous? before we get here; only the disjoint cases remain.
    def transform_ri(a, b)
      if b.start <= a.start
        [Prim.new(a.start + b.ilength, a.finish + b.ilength, a.text, a.priority)]
      elsif b.start >= a.finish
        [a]
      else
        # Unreachable: insert strictly inside a replace routes to transform_opaque.
        # There is no correct prim split (both halves would carry a.text and
        # duplicate the content), so fail loudly if this invariant is broken.
        raise "transform_ri: insert inside replace must route to opaque (invariant violated)"
      end
    end

    # replace a vs delete b
    def transform_rd(a, b)
      if a.finish <= b.start
        [a]
      elsif a.start >= b.finish
        [Prim.new(a.start - b.length, a.finish - b.length, a.text, a.priority)]
      elsif b.start <= a.start && b.finish >= a.finish
        # b covers a entirely: a's region gone, a.text survives as insert
        [Prim.new(b.start, b.start, a.text, a.priority)]
      else
        # Unreachable: overlapping replace/delete routes to transform_opaque.
        # Splitting would carry a.text on both remnants and duplicate content.
        raise "transform_rd: overlapping replace/delete must route to opaque (invariant violated)"
      end
    end

    # replace a vs replace b (overlap already routed to opaque, so only non-overlap here)
    def transform_rr(a, b)
      if a.finish <= b.start
        [a]
      else
        [Prim.new(a.start - (b.length - b.ilength), a.finish - (b.length - b.ilength), a.text, a.priority)]
      end
    end

    def to_prims(delta, base)
      case delta.type
      when 'setContents'
        # "These are my changes": diff against the parent content (base) into
        # splices so concurrent edits can merge, instead of an opaque clobber.
        diff_prims(base.to_s, delta.data, delta.priority_for(base))
      when 'insertDataSingleLine', 'insertDataMultiLine'
        o = base.offset(delta.start_line, delta.start_char)
        [Prim.new(o, o, delta.data, delta.priority_for(base))]
      when 'deleteDataSingleLine', 'deleteDataMultiLine'
        s = base.offset(delta.start_line, delta.start_char)
        e = delta.type == 'deleteDataSingleLine' ? base.offset(delta.start_line, delta.end_char) : base.offset(delta.end_line, delta.end_char)
        [Prim.new(s, e, '', delta.priority_for(base))]
      when 'replaceDataSingleLine', 'replaceDataMultiLine'
        s = base.offset(delta.start_line, delta.start_char)
        e = delta.type == 'replaceDataSingleLine' ? base.offset(delta.start_line, delta.end_char) : base.offset(delta.end_line, delta.end_char)
        [Prim.new(s, e, delta.data, delta.priority_for(base))]
      when 'pcreReplaceSingleLine', 'pcreReplaceMultiLine'
        # Expand the regex matches into atomic replace prims, so a pcre revision
        # can be folded against concurrent edits at the prim level instead of
        # erroring with "unknown delta type".
        delta.matches(base).map { |b, e, rep| Prim.new(b, e, rep, delta.priority_for(base)) }
      else
        raise ArgumentError, "unknown delta type #{delta.type}"
      end
    end

    def to_delta(prim, buf)
      sl, sc = buf.position(prim.start)
      el, ec = buf.position(prim.finish)
      if prim.delete?
        { type: 'deleteDataMultiLine', startLine: sl, startChar: sc, endLine: el, endChar: ec }
      elsif prim.insert?
        { type: 'insertDataMultiLine', startLine: sl, startChar: sc, data: prim.text }
      else
        { type: 'replaceDataMultiLine', startLine: sl, startChar: sc, endLine: el, endChar: ec, data: prim.text }
      end
    end
  end
end
