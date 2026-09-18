# frozen_string_literal: true
# One committed project merge (ADR-042): `source` as it was at `seq` went into
# `target`. The project graph draws these as merge edges.
class ProjectMergeRecord < ApplicationRecord
  self.table_name = 'project_merges'
  belongs_to :source, class_name: 'ProjectBranch'
  belongs_to :target, class_name: 'ProjectBranch'
end
