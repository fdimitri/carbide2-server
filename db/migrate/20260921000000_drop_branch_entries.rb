# frozen_string_literal: true
# The live path index is the merkle project DAG (project_trees /
# project_tree_entries, ProjectBranch#head_node). branch_entries was the
# mutated-tip copy from before that and has not been written since
# AddProjectDag. Drop it so nobody treats the stale rows as a cut at S.
class DropBranchEntries < ActiveRecord::Migration[8.1]
  def up
    drop_table :branch_entries
  end

  def down
    create_table :branch_entries do |t|
      t.uuid     :project_branch_id, null: false
      t.uuid     :file_node_id, null: false
      t.string   :path, null: false
      t.string   :ftype, default: 'file', null: false
      t.uuid     :content_branch_id
      t.uuid     :revision_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :branch_entries, %i[project_branch_id file_node_id], unique: true, name: 'index_branch_entries_node'
    add_index :branch_entries, %i[project_branch_id path], unique: true, where: 'deleted_at IS NULL',
              name: 'index_branch_entries_live_path'
    add_index :branch_entries, %i[project_branch_id path], name: 'index_branch_entries_path'
  end
end
