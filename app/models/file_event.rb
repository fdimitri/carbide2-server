# frozen_string_literal: true
# Append-only existence/identity log for a project's file nodes (ADR-042).
# `branch_entries.path` / `deleted_at` are the *current* index of a project
# branch (including main); the fold of a node's events with seq <= S is its
# existence and path at S.
class FileEvent < ApplicationRecord
  belongs_to :file_node
  belongs_to :project_branch, optional: true

  KINDS = %w[created deleted restored renamed].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :upto, ->(seq) { where(seq: ..seq) }
end
