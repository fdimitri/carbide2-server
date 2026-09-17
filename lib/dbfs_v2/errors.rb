# frozen_string_literal: true
module DbfsV2
  # Raised when a concurrent edit cannot be reconciled with the incoming one
  # without a human decision (overlapping replace/setContents). The write is
  # refused and nothing is committed; the conflict is surfaced rather than
  # silently resolved.
  class ConflictError < StandardError; end

  # A ConflictError between two known sets of changes. `regions` is
  # [{ target:, source: }] with each side's change regions ({ start:, end:,
  # type: }) in one coordinate space, the shape Merge#conflicts reports.
  class OverlapConflict < ConflictError
    attr_reader :regions

    def initialize(message, regions: [])
      super(message)
      @regions = regions
    end
  end
end
