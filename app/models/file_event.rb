# frozen_string_literal: true
# Notifications for a path op (created / deleted / restored / renamed).
# The project tree is the DAG, not a fold of these rows.
class FileEvent < ApplicationRecord
  belongs_to :file_node
  belongs_to :project_branch, optional: true

  KINDS = %w[created deleted restored renamed].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :upto, ->(seq) { where(seq: ..seq) }
end
