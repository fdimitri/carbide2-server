class AddUuidToProjectsAndControlUuidToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :uuid, :string
    add_column :users, :control_uuid, :string

    # Both are MIRRORS of control-owned identity. NULL means "not yet synced";
    # the pod does not fabricate a stable identity control knows nothing about.
    # Resolution falls back (Project.canonical / email) until control hands
    # down the uuid. Multiple NULLs are allowed by the unique index.
    add_index :projects, :uuid, unique: true
    add_index :users, :control_uuid, unique: true
  end

  def down
    remove_column :users, :control_uuid
    remove_column :projects, :uuid
  end
end
