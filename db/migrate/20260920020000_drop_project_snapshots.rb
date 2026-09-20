# frozen_string_literal: true
# Named project state is a ProjectNode (kind: snapshot). The old
# (seq, branch_set, manifest) table is unused.
class DropProjectSnapshots < ActiveRecord::Migration[8.1]
  def up
    drop_table :project_snapshots
  end

  def down
    create_table :project_snapshots, id: :uuid do |t|
      t.bigint :project_id, null: false
      t.string :name, null: false
      t.bigint :seq, null: false
      t.text :branch_set, null: false
      t.text :manifest, null: false
      t.bigint :user_id
      t.datetime :created_at, null: false
    end
    add_index :project_snapshots, %i[project_id name], unique: true
    add_index :project_snapshots, %i[project_id seq]
  end
end
