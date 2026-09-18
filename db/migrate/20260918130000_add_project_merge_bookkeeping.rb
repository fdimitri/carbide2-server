# frozen_string_literal: true
# ADR-042: the merge base between a project branch and its parent moves with
# each merge between them. (base_branch_id, base_seq) names the state that is
# the common ancestor for the next merge: the parent at the fork to begin
# with, then the merge's source at the merge's seq (after merging the branch
# into its parent the parent contains the branch as it was; after pulling the
# parent in, the branch contains the parent as it was).
#
# project_merges is the record of each committed merge — the project graph's
# merge edges (source at `seq` into target).
class AddProjectMergeBookkeeping < ActiveRecord::Migration[8.0]
  def up
    add_column :project_branches, :base_seq, :bigint
    add_column :project_branches, :base_branch_id, :uuid
    execute 'UPDATE project_branches SET base_seq = fork_seq, base_branch_id = forked_from_id'

    create_table :project_merges do |t|
      t.bigint :project_id, null: false
      t.uuid   :source_id,  null: false
      t.uuid   :target_id,  null: false
      t.bigint :seq,        null: false
      t.bigint :base_seq
      t.bigint :user_id
      t.datetime :created_at, null: false
    end
    add_index :project_merges, %i[project_id seq]
  end

  def down
    drop_table :project_merges
    remove_column :project_branches, :base_branch_id
    remove_column :project_branches, :base_seq
  end
end
