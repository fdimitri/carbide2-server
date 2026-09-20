# frozen_string_literal: true
# Per-branch reflog: one row per head move, stamped with the project seq.
class BranchHead < ApplicationRecord
  belongs_to :branch
end
