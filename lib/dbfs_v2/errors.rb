# frozen_string_literal: true
module DbfsV2
  # Raised when a concurrent edit cannot be reconciled with the incoming one
  # without a human decision (overlapping replace/setContents). The write is
  # refused and nothing is committed; the conflict is surfaced rather than
  # silently resolved.
  class ConflictError < StandardError; end
end
