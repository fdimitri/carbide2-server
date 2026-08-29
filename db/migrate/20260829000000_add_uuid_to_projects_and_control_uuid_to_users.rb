class AddUuidToProjectsAndControlUuidToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :uuid, :string
    add_column :users, :control_uuid, :string

    # projects.uuid is the control-owned project identity (== workspace uuid
    # under 1:1). Backfill local rows with an independent uuid.
    Project.find_each { |p| p.update_columns(uuid: SecureRandom.uuid) }

    add_index :projects, :uuid, unique: true
    # users.control_uuid mirrors control's user uuid; nullable until the pod
    # first resolves that user from a control token. Multiple NULLs are allowed.
    add_index :users, :control_uuid, unique: true

    change_column_null :projects, :uuid, false
  end

  def down
    remove_column :users, :control_uuid
    remove_column :projects, :uuid
  end
end
