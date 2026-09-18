# frozen_string_literal: true
# ADR-042: the merge base between a project branch and its parent moves with
# each merge between them. (base_branch_id, base_seq) names the state that is
# the common ancestor for the next merge: the parent at the fork to begin
# with, then the merge's source at the merge's seq (after merging the branch
# into its parent the parent contains the branch as it was; after pulling the
# parent in, the branch contains the parent as it was).
class AddBaseSeqToProjectBranches < ActiveRecord::Migration[8.0]
  def up
    add_column :project_branches, :base_seq, :bigint
    add_column :project_branches, :base_branch_id, :uuid
    execute 'UPDATE project_branches SET base_seq = fork_seq, base_branch_id = forked_from_id'
  end

  def down
    remove_column :project_branches, :base_branch_id
    remove_column :project_branches, :base_seq
  end
end
