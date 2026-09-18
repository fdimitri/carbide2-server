# frozen_string_literal: true
# Per-branch reflog (ADR-042): one row per head move, stamped with the project
# seq it happened at. Written by Branch#log_head; read by ProjectState to find
# a branch's head at a cut.
class BranchHead < ApplicationRecord
  belongs_to :branch
end
