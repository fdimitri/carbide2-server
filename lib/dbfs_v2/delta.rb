# frozen_string_literal: true
require "digest"
module DbfsV2
  # Delta — a single revision operation. Each delta normalizes to a flat
  # character range [start, end] and an inserted text, which is the only shape
  # the OT transform needs to reason about. Line/char coordinates are the
  # wire/replay format; offsets are the transform format.
  class Delta
    attr_reader :type, :payload

    def initialize(type, payload = {})
      @type = type.to_s
      @payload = symbolize_keys(payload)
    end

    def self.parse(type, data)
      new(type, data.is_a?(Hash) ? data : JSON.parse(data.to_s))
    end

    # --- wire coords -------------------------------------------------------
    def start_line = @payload[:startLine].to_i
    def start_char = @payload[:startChar].to_i
    def end_line   = @payload[:endLine].to_i
    def end_char   = @payload[:endChar].to_i
    def data       = @payload[:data].to_s

    # --- PCRE replace -----------------------------------------------------
    # payload: { pattern:, replacement:, limit: 0 }  (limit 0 == unlimited)
    def pattern     = @payload[:pattern].to_s
    def replacement = @payload[:replacement].to_s
    def limit       = (@payload[:limit] || 0).to_i

    # --- normalized range (flat char offsets) ------------------------------
    # Returns [start, end] over the JOINED string (newline = 1 char).
    def range(buffer)
      case @type
      when 'setContents'
        [0, buffer.to_s.length]
      when 'insertDataSingleLine', 'insertDataMultiLine'
        o = buffer.offset(start_line, start_char)
        [o, o]
      when 'deleteDataSingleLine'
        s = buffer.offset(start_line, start_char)
        e = buffer.offset(start_line, end_char)
        [s, e]
      when 'deleteDataMultiLine'
        s = buffer.offset(start_line, start_char)
        e = buffer.offset(end_line, end_char)
        [s, e]
      when 'replaceDataSingleLine'
        s = buffer.offset(start_line, start_char)
        e = buffer.offset(start_line, end_char)
        [s, e]
      when 'replaceDataMultiLine'
        s = buffer.offset(start_line, start_char)
        e = buffer.offset(end_line, end_char)
        [s, e]
      else
        raise ArgumentError, "unknown delta type #{@type}"
      end
    end

    # Text this delta introduces at its range ('' for pure deletes).
    def text
      case @type
      when 'insertDataSingleLine', 'insertDataMultiLine', 'replaceDataSingleLine', 'replaceDataMultiLine'
        data
      else
        ''
      end
    end

    def deletion?
      %w[deleteDataSingleLine deleteDataMultiLine].include?(@type)
    end

    def insertion?
      %w[insertDataSingleLine insertDataMultiLine].include?(@type)
    end

    def replacement?
      %w[replaceDataSingleLine replaceDataMultiLine].include?(@type)
    end

    def set_contents?
      @type == 'setContents'
    end

    def pcre_replace?
      %w[pcreReplaceSingleLine pcreReplaceMultiLine].include?(@type)
    end

    def pcre_multiline?
      @type == 'pcreReplaceMultiLine'
    end

    # Find all PCRE matches against `buffer`, each as [begin, end, expanded
    # replacement]. `begin`/`end` are flat character offsets over the joined
    # string. Honors `limit` (0 == unlimited). Public so Transform#to_prims can
    # decompose the replace into splices for OT.
    def matches(buffer)
      content = buffer.to_s
      re = Regexp.new(pattern, pcre_multiline? ? Regexp::MULTILINE : 0)
      out = []
      pos = 0
      n   = 0
      # pos can pass the end after a zero-width match there; Regexp#match(str,
      # len + 1) still matches at len, so stop explicitly or this never ends.
      while pos <= content.length && (m = re.match(content, pos))
        b   = m.begin(0)
        e   = m.end(0)
        pos = e > b ? e : e + 1          # advance past zero-width matches
        next if !pcre_multiline? && content[b...e].to_s.include?("\n") # single-line bound
        out << [b, e, expand_replacement(replacement, m)]
        n += 1
        break if limit.positive? && n >= limit
      end
      out
    end

    # --- apply -------------------------------------------------------------
    def apply_to(buffer)
      case @type
      when 'setContents'
        buffer.set_contents(data)
      when 'insertDataSingleLine', 'insertDataMultiLine'
        buffer_insert(buffer, start_line, start_char, data)
      when 'deleteDataSingleLine'
        buffer_delete(buffer, start_line, start_char, start_line, end_char)
      when 'deleteDataMultiLine'
        buffer_delete(buffer, start_line, start_char, end_line, end_char)
      when 'replaceDataSingleLine'
        buffer_delete(buffer, start_line, start_char, start_line, end_char)
        buffer_insert(buffer, start_line, start_char, data)
      when 'replaceDataMultiLine'
        buffer_delete(buffer, start_line, start_char, end_line, end_char)
        buffer_insert(buffer, start_line, start_char, data)
      when 'pcreReplaceSingleLine', 'pcreReplaceMultiLine'
        apply_pcre(buffer)
      end
      buffer
    end

    # Deterministic tie-break priority for OT. Callers SHOULD supply the
    # revision id for a true total order; falls back to a stable content hash.
    attr_accessor :priority

    def priority_for(_base)
      @priority ||= Digest::SHA1.hexdigest(@type + "|" + @payload.to_json)
    end

    # Fail-closed validation for an INCOMING client delta: reject out-of-range
    # line/char coordinates instead of silently clamping them (a stale client
    # that thinks the file is longer would otherwise apply a different edit than
    # it intended, and OT would "converge" on the wrong document).
    #
    # Only applied at the write() boundary against the client's stated base.
    # Internal OT re-encoding still uses Buffer clamping for transformed coords.
    # setContents / PCRE carry no line/char coords; writeBinary is not text.
    def validate_against!(buffer)
      if %w[pcreReplaceSingleLine pcreReplaceMultiLine].include?(@type)
        # Compile AND expand the replacement now, so a bad pattern or an
        # unknown backreference (${nope}, \k<nope>) fails closed BEFORE the
        # write commits — otherwise the revision lands and every later read
        # raises (a poisoned file).
        matches(buffer)
        return self
      end
      return self if %w[setContents writeBinary].include?(@type)

      check = lambda do |line, char, label|
        max_line = buffer.line_count - 1
        if line < 0 || line > max_line
          raise ArgumentError, "#{@type}: #{label} line #{line} out of range (0..#{max_line})"
        end
        len = buffer.line(line).length
        if char < 0 || char > len
          raise ArgumentError, "#{@type}: #{label} char #{char} out of range on line #{line} (0..#{len})"
        end
      end

      case @type
      when 'insertDataSingleLine', 'insertDataMultiLine'
        check.call(start_line, start_char, 'start')
      when 'deleteDataSingleLine', 'replaceDataSingleLine'
        check.call(start_line, start_char, 'start')
        check.call(start_line, end_char, 'end')
      when 'deleteDataMultiLine', 'replaceDataMultiLine'
        check.call(start_line, start_char, 'start')
        check.call(end_line, end_char, 'end')
      end

      # Reject inverted ranges (end before start) — a no-op that silently does
      # nothing is worse than a loud failure.
      if %w[deleteDataMultiLine replaceDataMultiLine].include?(@type) && ordered_before?
        raise ArgumentError, "#{@type}: end (#{end_line},#{end_char}) is before start (#{start_line},#{start_char})"
      end
      self
    end

    # True when (end_line,end_char) < (start_line,start_char).
    def ordered_before?
      end_line < start_line || (end_line == start_line && end_char < start_char)
    end

    def to_h
      { type: @type }.merge(@payload)
    end

    def to_json(*)
      to_h.to_json(*)
    end

    private

    def symbolize_keys(h)
      h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    # Insert `text` at (line, char). `text` may contain newlines.
    def buffer_insert(buffer, line, char, text)
      # "".split("\n", -1) is [], which the splice below can't handle; an empty
      # insert is a no-op.
      return if text.empty?
      line = [[line, 0].max, buffer.lines.length - 1].min
      buffer.lines[line] ||= ''
      char = [char, buffer.lines[line].length].min
      parts = text.split("\n", -1)
      head = buffer.lines[line][0...char].to_s
      tail = buffer.lines[line][char..].to_s
      if parts.length == 1
        buffer.lines[line] = head + parts[0] + tail
      else
        buffer.lines[line] = head + parts[0]
        (1...parts.length).each { |i| buffer.lines.insert(line + i, parts[i]) }
        buffer.lines[line + parts.length - 1] += tail
      end
    end

    def buffer_delete(buffer, sl, sc, el, ec)
      return if sl > el || (sl == el && sc >= ec)

      first = buffer.lines[sl] || ''
      last  = buffer.lines[el] || ''
      left  = first[0...sc].to_s
      right = (sl == el ? first[ec..] : last[ec..]).to_s
      buffer.lines.slice!(sl, el - sl + 1)
      buffer.lines.insert(sl, left + right)
    end

    # Apply a PCRE replace to the buffer: splice each match's replacement in
    # right-to-left so flat offsets stay valid, then rebuild the line model.
    def apply_pcre(buffer)
      content = buffer.to_s
      matches(buffer).reverse_each do |b, e, rep|
        content = content[0...b] + rep + content[e..]
      end
      buffer.set_contents(content)
      buffer
    end

    # Expand backreferences in a replacement string against a MatchData.
    # Supports Ruby-style (\0 \& \1..\9 \k<name> \\) and PHP/preg-style
    # ($0 $1..$9 ${name} $$) tokens.
    def expand_replacement(replacement, m)
      out = +''
      i = 0
      while i < replacement.length
        ch = replacement[i]
        if ch == '\\' && i + 1 < replacement.length
          nxt = replacement[i + 1]
          case nxt
          when '\\' then out << '\\'; i += 2
          when '0', '&' then out << m[0].to_s; i += 2
          when 'k'
            if replacement[i + 2] == '<'
              close = replacement.index('>', i + 3)
              out << (close ? (m[replacement[(i + 3)...close]] || '').to_s : '')
              i = close ? close + 1 : i + 2
            else
              out << nxt; i += 2
            end
          when '1'..'9' then out << (m[nxt.to_i] || '').to_s; i += 2
          else out << nxt; i += 2
          end
        elsif ch == '$' && i + 1 < replacement.length
          nxt = replacement[i + 1]
          case nxt
          when '$' then out << '$'; i += 2
          when '0' then out << m[0].to_s; i += 2
          when '1'..'9' then out << (m[nxt.to_i] || '').to_s; i += 2
          when '{'
            close = replacement.index('}', i + 2)
            out << (close ? (m[replacement[(i + 2)...close]] || '').to_s : '')
            i = close ? close + 1 : i + 2
          else out << ch; i += 1
          end
        else
          out << ch; i += 1
        end
      end
      out
    end
  end
end
