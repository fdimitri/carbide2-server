# frozen_string_literal: true
module DbfsV2
  # Buffer — the in-memory text document. Content is modeled as an array of
  # lines (each WITHOUT a trailing newline). An empty file is [""]. Line/char
  # coordinates are 0-based and address positions BETWEEN characters.
  class Buffer
    attr_reader :lines

    def initialize(content = '')
      set_contents(content)
    end

    def set_contents(content)
      str = content.to_s
      @lines = str.empty? ? [""] : str.split("\n", -1)
      self
    end

    def to_s
      @lines.join("\n")
    end
    alias content to_s

    def line_count
      @lines.length
    end

    def line(n)
      @lines[n] || ''
    end

    # Flatten a (line, char) position to a single integer offset in the joined
    # string (characters, not bytes).
    def offset(line, char)
      line = [[line.to_i, 0].max, @lines.length - 1].min
      char = [[char.to_i, 0].max, @lines[line].length].min
      @lines[0...line].sum { |l| l.length + 1 } + char
    end

    # Inverse of #offset: integer offset -> [line, char].
    def position(offset)
      offset = [offset.to_i, 0].max
      acc = 0
      @lines.each_with_index do |l, i|
        if offset <= acc + l.length
          return [i, offset - acc]
        end
        acc += l.length + 1
      end
      [@lines.length - 1, @lines.last.length]
    end

    def apply(delta)
      delta.apply_to(self)
    end
  end
end
