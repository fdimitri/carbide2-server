# frozen_string_literal: true
# The project DAG: every path op appends an immutable node (paths → UUID →
# live content line). A project branch tip is a pointer at the latest running
# node. Explicit snapshots are nodes in the same table with frozen revision
# pointers. This replaces branch_entries as a mutated tip.
class AddProjectDag < ActiveRecord::Migration[8.1]
  def up
    create_table :project_nodes, id: :string, limit: 64 do |t|
      t.bigint  :project_id, null: false
      t.uuid    :project_branch_id, null: false
      t.string  :parent_id, limit: 64
      t.string  :second_parent_id, limit: 64
      t.string  :kind, null: false, default: 'running'
      t.string  :name
      t.bigint  :user_id
      t.timestamps
    end
    add_index :project_nodes, :project_id
    add_index :project_nodes, :project_branch_id
    add_index :project_nodes, %i[project_id kind]
    add_index :project_nodes, %i[project_id name], unique: true, where: "kind = 'snapshot' AND name IS NOT NULL",
              name: 'index_project_nodes_snapshot_name'

    create_table :project_node_entries do |t|
      t.string :project_node_id, limit: 64, null: false
      t.uuid   :file_node_id, null: false
      t.string :path, null: false
      t.string :ftype, null: false, default: 'file'
      t.uuid   :content_branch_id
      t.uuid   :revision_id
      t.timestamps
    end
    add_index :project_node_entries, %i[project_node_id path], unique: true, name: 'index_project_node_entries_path'
    add_index :project_node_entries, %i[project_node_id file_node_id], unique: true, name: 'index_project_node_entries_node'

    add_column :project_branches, :head_node_id, :string, limit: 64
    add_column :project_branches, :fork_node_id, :string, limit: 64
    add_column :project_branches, :base_node_id, :string, limit: 64
    add_index  :project_branches, :head_node_id

    execute <<~SQL
      INSERT INTO project_nodes (id, project_id, project_branch_id, kind, created_at, updated_at)
      SELECT md5(pb.id::text || ':genesis') || md5(pb.id::text),
             pb.project_id, pb.id, 'running', now(), now()
      FROM project_branches pb
      WHERE pb.deleted_at IS NULL
        AND EXISTS (SELECT 1 FROM branch_entries e WHERE e.project_branch_id = pb.id AND e.deleted_at IS NULL);

      INSERT INTO project_node_entries (
        project_node_id, file_node_id, path, ftype, content_branch_id, revision_id, created_at, updated_at
      )
      SELECT n.id, e.file_node_id, e.path, e.ftype, e.content_branch_id, e.revision_id, now(), now()
      FROM branch_entries e
      JOIN project_nodes n ON n.project_branch_id = e.project_branch_id AND n.kind = 'running' AND n.parent_id IS NULL
      WHERE e.deleted_at IS NULL AND e.path <> '/';

      UPDATE project_branches pb
      SET head_node_id = n.id, fork_node_id = COALESCE(pb.fork_node_id, n.parent_id),
          base_node_id = COALESCE(pb.base_node_id, n.parent_id)
      FROM project_nodes n
      WHERE n.project_branch_id = pb.id AND n.kind = 'running' AND pb.head_node_id IS NULL;
    SQL
  end

  def down
    remove_column :project_branches, :base_node_id
    remove_column :project_branches, :fork_node_id
    remove_column :project_branches, :head_node_id
    drop_table :project_node_entries
    drop_table :project_nodes
  end
end
