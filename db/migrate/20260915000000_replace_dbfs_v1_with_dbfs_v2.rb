# Replace DBFS v1 (directory_entries + file_changes) with DBFS v2 — a per-file
# DAG revision store. See lib/dbfs_v2 and docs/dbfs_v2/.
#
# No data is migrated: v1 rows are dropped outright. The v1 create migrations
# are removed from the tree, so on a fresh database the drops are no-ops.
#
# Consolidates the prototype's 001..005 migrations into one Postgres schema:
#
#   file_nodes — one row per filesystem node (tombstoned via deleted_at, never
#                destroyed); parent_id is the tree edge, path the address.
#   branches   — first-class named branch per node, head_revision_id pointer.
#   revisions  — the DAG: parent_id / second_parent_id (non-nil => merge).
#   keyframes  — full-content snapshots that only accelerate replay.
#   blobs      — content-addressed byte archive (sha256 digest PK, bytea).
#
# DAG pointers (revisions.parent_id / second_parent_id, branches.head_revision_id,
# keyframes.revision_id, file_nodes.parent_id) are deliberately NOT foreign
# keys: revisions, branches and keyframes reference each other circularly, and
# ancestry is validated by the store (Chain), not by the database.
#
# The structural foreign keys cascade on delete. Application code never
# destroys a FileNode (deletes are tombstones); the cascade exists so that
# destroying a whole Project removes its filesystem instead of failing on the
# constraint. blobs are shared, content-addressed rows and are not project-owned.
class ReplaceDbfsV1WithDbfsV2 < ActiveRecord::Migration[8.1]
  def up
    drop_table :file_changes,      if_exists: true
    drop_table :directory_entries, if_exists: true

    create_table :file_nodes, id: :uuid do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false # covered by [project_id, path]
      t.uuid     :parent_id                                  # containing folder; nil = root
      t.string   :path,       null: false                    # absolute, normalized, leading '/'
      t.string   :cur_name
      t.string   :ftype,      null: false, default: 'file'   # 'file' | 'folder'
      t.boolean  :binary,     null: false, default: false
      t.string   :owner,      null: false                    # POSIX owner (name or numeric uid)
      t.string   :posix_group
      t.integer  :posix_mode, null: false, default: 0o644
      t.string   :symlink_target                             # nil => not a symlink (normalized DBFS path)
      t.bigint   :last_size
      t.datetime :mtime
      t.bigint   :created_by                                 # users.id; nil for system/external writes
      t.datetime :deleted_at                                 # tombstone
      t.timestamps
    end
    add_index :file_nodes, [:project_id, :path], unique: true
    add_index :file_nodes, :parent_id
    add_index :file_nodes, [:project_id, :parent_id]
    add_index :file_nodes, [:project_id, :cur_name]
    add_index :file_nodes, [:project_id, :deleted_at]

    create_table :branches, id: :uuid do |t|
      t.references :file_node, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.string :name, null: false
      t.uuid   :head_revision_id
      t.timestamps
    end
    add_index :branches, [:file_node_id, :name], unique: true

    create_table :revisions, id: :uuid do |t|
      t.references :file_node, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.references :branch,    type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.uuid     :parent_id                                  # first parent (nil => genesis)
      t.uuid     :second_parent_id                           # non-nil => merge commit
      t.string   :change_type, null: false
      t.text     :change_data                                # JSON payload
      t.bigint   :user_id                                    # users.id; nil for system/external writes
      t.string   :priority                                   # OT tie-break
      t.datetime :timestamp, null: false
    end
    add_index :revisions, :parent_id
    add_index :revisions, :second_parent_id

    create_table :keyframes, id: :uuid do |t|
      t.references :file_node, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.uuid :revision_id, null: false
      t.text :content,     null: false
      t.timestamps
    end
    add_index :keyframes, [:file_node_id, :revision_id], unique: true

    create_table :blobs, id: false do |t|
      t.string :digest, primary_key: true, null: false       # sha256 hex
      t.binary :content, null: false                         # bytea
      t.bigint :size,    null: false
      t.timestamps
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'DBFS v1 is gone; there is nothing to restore'
  end
end
