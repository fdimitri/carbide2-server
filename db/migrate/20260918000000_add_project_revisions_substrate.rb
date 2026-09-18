# ADR-042: a project state is (S, B) — a cut S through the project's single
# sequenced log, resolved through a branch set B. This adds the log.
#
#   project_clocks   — one monotonic counter per project, ticked INSIDE the
#                      writing transaction (DbfsV2::Clock), so seq order is
#                      commit order. A SEQUENCE would not be.
#   revisions.seq    — the tick a revision took; project_id denormalized so a
#                      cut ("newest rev with seq <= S") is one indexed scan.
#   file_events      — append-only existence/identity log: created, deleted,
#                      restored, renamed. file_nodes.path / deleted_at remain
#                      the *current* index; they are no longer the only record.
#   branches         — born with a seq and an origin revision; deleted by
#                      tombstone (deleted_at) instead of re-homing revisions,
#                      because re-homing rewrites which branch a revision was
#                      on and would change a past state after the fact. The
#                      name uniqueness index becomes partial so a deleted
#                      branch's name can be reused.
#   branch_heads     — per-branch reflog of head moves (Branch#log_head), so
#                      the head at S is known even across fast-forwards,
#                      which move the pointer without creating a revision.
#   project_snapshots — named states: (S, B) plus the manifest materialized
#                      from them, so the name survives anything done to the
#                      DAG later.
#
# Backfill: everything that exists before this migration is "prehistory",
# seq 0 — one undifferentiated state. Every node gets a `created` event at 0
# (plus a `deleted` at 0 if tombstoned) so the fold has a starting point.
class AddProjectRevisionsSubstrate < ActiveRecord::Migration[8.1]
  def up
    create_table :project_clocks, id: false do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :seq, null: false, default: 0
    end
    add_index :project_clocks, :project_id, unique: true

    add_column :revisions, :seq, :bigint, null: false, default: 0
    add_column :revisions, :project_id, :bigint
    execute <<~SQL
      UPDATE revisions SET project_id = file_nodes.project_id
      FROM file_nodes WHERE file_nodes.id = revisions.file_node_id
    SQL
    add_index :revisions, [:project_id, :seq]
    add_index :revisions, [:branch_id, :seq]

    add_column :branches, :seq, :bigint, null: false, default: 0
    add_column :branches, :origin_revision_id, :uuid
    add_column :branches, :deleted_at, :datetime
    add_column :branches, :deleted_seq, :bigint
    remove_index :branches, [:file_node_id, :name]
    add_index :branches, [:file_node_id, :name], unique: true, where: 'deleted_at IS NULL',
              name: 'index_branches_on_file_node_id_and_name_live'

    # Per-branch reflog: every head move, stamped. A fast-forward moves the
    # head onto a revision committed on another branch without creating one,
    # so "newest revision on b with seq <= S" is not b's head at S; this is.
    create_table :branch_heads do |t|
      t.references :branch, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :seq,         null: false
      t.uuid   :revision_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :branch_heads, [:branch_id, :seq]
    execute <<~SQL
      INSERT INTO branch_heads (branch_id, seq, revision_id, created_at)
      SELECT id, 0, head_revision_id, updated_at FROM branches WHERE head_revision_id IS NOT NULL
    SQL

    create_table :file_events do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint  :seq,          null: false
      t.uuid    :file_node_id, null: false
      t.string  :kind,         null: false                  # created | deleted | restored | renamed
      t.string  :path,         null: false                  # the node's path after the event
      t.string  :from_path                                  # renamed: the path before
      t.string  :ftype,        null: false, default: 'file'
      t.bigint  :user_id
      t.datetime :created_at,  null: false
    end
    add_index :file_events, [:project_id, :seq]
    add_index :file_events, [:file_node_id, :seq]
    add_foreign_key :file_events, :file_nodes, column: :file_node_id, on_delete: :cascade

    execute <<~SQL
      INSERT INTO file_events (project_id, seq, file_node_id, kind, path, ftype, user_id, created_at)
      SELECT project_id, 0, id, 'created', path, ftype, created_by, created_at FROM file_nodes
    SQL
    execute <<~SQL
      INSERT INTO file_events (project_id, seq, file_node_id, kind, path, ftype, created_at)
      SELECT project_id, 0, id, 'deleted', path, ftype, deleted_at FROM file_nodes WHERE deleted_at IS NOT NULL
    SQL

    create_table :project_snapshots, id: :uuid do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name,       null: false
      t.bigint :seq,        null: false
      t.text   :branch_set, null: false                     # JSON: { name, overrides }
      t.text   :manifest,   null: false                     # JSON: materialized ProjectState
      t.bigint :user_id
      t.datetime :created_at, null: false
    end
    add_index :project_snapshots, [:project_id, :name], unique: true
    add_index :project_snapshots, [:project_id, :seq]
  end

  def down
    drop_table :project_snapshots
    drop_table :file_events
    drop_table :branch_heads
    remove_index :branches, name: 'index_branches_on_file_node_id_and_name_live'
    add_index :branches, [:file_node_id, :name], unique: true
    remove_column :branches, :deleted_seq
    remove_column :branches, :deleted_at
    remove_column :branches, :origin_revision_id
    remove_column :branches, :seq
    remove_column :revisions, :project_id
    remove_column :revisions, :seq
    drop_table :project_clocks
  end
end
