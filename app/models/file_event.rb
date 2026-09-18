# frozen_string_literal: true
# Append-only existence/identity log for a project's file nodes (ADR-042).
# `file_nodes.path` / `deleted_at` are the *current* index; the fold of a
# node's events with seq <= S is its existence and path at S.
class FileEvent < ApplicationRecord
  belongs_to :file_node
  belongs_to :project_branch, optional: true

  KINDS = %w[created deleted restored renamed].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :upto, ->(seq) { where(seq: ..seq) }
end
