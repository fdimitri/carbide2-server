# Project branches (ADR-042, step 2): a branch of the whole project, with its
# own existence/identity log and a per-branch path index.
#
#   project_branches  the row. uuid identity, so a tombstoned name can be
#                     reused without reviving the old branch's history (the
#                     old row keeps its uuid, events, entries and content).
#                     `main` is a row like any other; its index is file_nodes.
#   branch_entries    the CURRENT path index of a non-main branch: one row per
#                     node the branch has (full copy at fork, not shallow).
#                     `revision_id` pins content at the fork until the branch's
#                     first write to that file creates `content_branch` (a
#                     branches row named after the project branch).
#   file_events       gain project_branch_id: which branch's existence log the
#                     event belongs to. ProjectState.at(S, P) folds P's events
#                     after its parent's up to fork_seq.
#   branches          gain project_branch_id: the project branch a per-file
#                     content branch belongs to (null = detached per-file
#                     branch, as before).
class AddProjectBranches < ActiveRecord::Migration[8.1]
  def up
    create_table :project_branches, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.bigint  :project_id, null: false
      t.string  :name, null: false
      t.uuid    :forked_from_id
      t.bigint  :fork_seq
      t.bigint  :seq, null: false, default: 0
      t.datetime :deleted_at
      t.bigint  :deleted_seq
      t.boolean :materialized, null: false, default: false
      t.bigint  :user_id
      t.timestamps
    end
    add_index :project_branches, %i[project_id name], unique: true, where: 'deleted_at IS NULL',
              name: 'index_project_branches_live_name'
    add_index :project_branches, :project_id

    create_table :branch_entries do |t|
      t.uuid   :project_branch_id, null: false
      t.uuid   :file_node_id, null: false
      t.string :path, null: false
      t.string :ftype, null: false, default: 'file'
      t.uuid   :revision_id
      t.uuid   :content_branch_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :branch_entries, %i[project_branch_id file_node_id], unique: true, name: 'index_branch_entries_node'
    add_index :branch_entries, %i[project_branch_id path], unique: true, where: 'deleted_at IS NULL',
              name: 'index_branch_entries_live_path'
    add_index :branch_entries, %i[project_branch_id path], name: 'index_branch_entries_path'

    add_column :file_events, :project_branch_id, :uuid
    add_index  :file_events, %i[project_branch_id seq]
    add_column :branches, :project_branch_id, :uuid
    add_index  :branches, :project_branch_id

    # Every project with history gets its main row, and what exists today is
    # main's: its events and its per-file 'main' branches.
    execute <<~SQL
      INSERT INTO project_branches (id, project_id, name, seq, created_at, updated_at)
      SELECT gen_random_uuid(), p.project_id, 'main', 0, now(), now()
      FROM (SELECT DISTINCT project_id FROM file_nodes
            UNION SELECT DISTINCT project_id FROM file_events) p;

      UPDATE file_events e SET project_branch_id = pb.id
      FROM project_branches pb
      WHERE pb.project_id = e.project_id AND pb.name = 'main' AND e.project_branch_id IS NULL;

      UPDATE branches b SET project_branch_id = pb.id
      FROM file_nodes n, project_branches pb
      WHERE b.file_node_id = n.id AND pb.project_id = n.project_id AND pb.name = 'main'
        AND b.name = 'main' AND b.project_branch_id IS NULL;
    SQL
  end

  def down
    remove_column :branches, :project_branch_id
    remove_column :file_events, :project_branch_id
    drop_table :branch_entries
    drop_table :project_branches
  end
end
