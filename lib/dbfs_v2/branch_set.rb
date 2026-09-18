# frozen_string_literal: true
module DbfsV2
  # BranchSet — the B in a project state (S, B) (ADR-042).
  #
  # A name plus optional per-file overrides. Per file, it resolves to that
  # file's branch called `overrides[file_id]` if given, else the one called
  # `name`, provided the branch was live at S; otherwise main. Server-made
  # auto/… branches are per-file conflict artifacts and never resolve.
  class BranchSet
    attr_reader :name, :overrides

    def self.wrap(x)
      case x
      when BranchSet then x
      when nil       then new(Branch::MAIN)
      when String, Symbol then new(x.to_s)
      when Hash
        h = x.transform_keys(&:to_s)
        new(h['name'] || Branch::MAIN, overrides: h['overrides'] || {})
      else raise ArgumentError, "not a branch set: #{x.inspect}"
      end
    end

    def initialize(name, overrides: {})
      raise ArgumentError, 'a branch set cannot be an auto-branch' if name.to_s.start_with?(Graph::AUTO_PREFIX)
      @name      = name.to_s
      @overrides = (overrides || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
    end

    def main? = @name == Branch::MAIN && @overrides.empty?

    # Candidate branch names for a file, most specific first; main is the
    # implicit last resort and not listed.
    def candidates(file_node_id)
      names = [@overrides[file_node_id.to_s], @name].compact.uniq
      names.reject { |n| n == Branch::MAIN || n.start_with?(Graph::AUTO_PREFIX) }
    end

    def to_h
      { name: @name, overrides: @overrides }
    end

    def ==(other)
      other.is_a?(BranchSet) && other.name == @name && other.overrides == @overrides
    end
    alias eql? ==
    def hash = [@name, @overrides].hash

    def to_s
      @overrides.empty? ? @name : "#{@name}+#{@overrides.size}"
    end
  end
end
