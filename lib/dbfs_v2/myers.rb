# frozen_string_literal: true
module DbfsV2
  # Myers O(ND) shortest-edit-script diff, returning replacement hunks.
  #
  # `hunks(a, b)` returns a list of [old_start, old_end, new_start, new_end]
  # replacements such that applying them left-to-right to `a` yields `b`:
  #   a[0...os1) + b[ns1...ne1) + a[oe1...os2) + ... + a[oen...]
  #
  # O(ND) time and O(D^2) space (D = number of inserted+deleted tokens), which
  # for realistic edits (a few changed lines) is tiny. A genuine full rewrite is
  # D = n + m; to bound memory we stop once D exceeds MAX_D and let the caller
  # fall back to a single coarse hunk (correct, just not minimal — and for a
  # full rewrite a single hunk is exactly right).
  module Myers
    MAX_D = 2048

    module_function

    # Returns hunks, or nil when the edit distance exceeds MAX_D.
    def hunks(a, b)
      n = a.length
      m = b.length
      return [] if n.zero? && m.zero?
      return [[0, n, 0, m]] if n.zero? || m.zero?

      # Trim the common token prefix and suffix first. This is the usual case
      # for real edits (change a few lines in a big file) and it is exact: any
      # minimal edit script keeps a common prefix/suffix unchanged, so only the
      # differing middle can contain hunks. It also collapses the fully-shared
      # case (one string a suffix of the other) to a single insert/delete.
      pre = 0
      pre += 1 while pre < n && pre < m && a[pre] == b[pre]
      suf = 0
      suf += 1 while suf < (n - pre) && suf < (m - pre) && a[n - 1 - suf] == b[m - 1 - suf]
      return [] if pre == n && pre == m

      mid_a = a[pre...(n - suf)]
      mid_b = b[pre...(m - suf)]
      middle = diff_middle(mid_a, mid_b)
      return nil if middle.nil?

      # Re-anchor the middle's hunks into full-array coordinates.
      middle.map { |os, oe, ns, ne| [os + pre, oe + pre, ns + pre, ne + pre] }
    end

    def diff_middle(a, b)
      n = a.length
      m = b.length
      return [] if n.zero? && m.zero?
      return [[0, n, 0, m]] if n.zero? || m.zero?

      v = { 1 => 0 }
      trace = []
      (0..(n + m)).each do |d|
        return nil if d > MAX_D
        trace << v.dup
        (-d).step(d, 2) do |k|
          x = if k == -d || (k != d && (v[k - 1] || -1) < (v[k + 1] || -1))
                v[k + 1] || 0
              else
                (v[k - 1] || 0) + 1
              end
          y = x - k
          while x < n && y < m && a[x] == b[y]
            x += 1
            y += 1
          end
          v[k] = x
          return hunks_from_matches(backtrack(trace, n, m), n, m) if x >= n && y >= m
        end
      end
      nil
    end

    # Walk the saved frontiers backwards, collecting matched (diagonal) pairs.
    def backtrack(trace, n, m)
      x = n
      y = m
      matches = []
      (trace.length - 1).downto(0) do |d|
        v = trace[d]
        k = x - y
        prev_k = if k == -d || (k != d && (v[k - 1] || -1) < (v[k + 1] || -1))
                   k + 1
                 else
                   k - 1
                 end
        prev_x = v[prev_k] || 0
        prev_y = prev_x - prev_k
        while x > prev_x && y > prev_y
          matches << [x - 1, y - 1]
          x -= 1
          y -= 1
        end
        x = prev_x
        y = prev_y
      end
      matches.reverse!
    end

    # Turn the matched token pairs into the maximal replacement hunks between
    # them. Matched tokens are (by construction) equal in a and b.
    def hunks_from_matches(matches, n, m)
      hunks = []
      ai = 0
      bi = 0
      matches.each do |ma, mb|
        hunks << [ai, ma, bi, mb] if ma > ai || mb > bi
        ai = ma + 1
        bi = mb + 1
      end
      hunks << [ai, n, bi, m] if ai < n || bi < m
      hunks
    end
  end
end
