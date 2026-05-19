# Create the database-backed virtual filesystem tables.
#
# directory_entries — virtual filesystem tree nodes (files and folders).
#   Each entry belongs to a project.  srcpath is the canonical path within
#   the project root, e.g. '/src/app.rb'.  owner_id is the parent folder.
#
# file_changes — append-only edit log for each file entry.
#   change_type values: setContents | insertDataSingleLine | insertDataMultiLine |
#                       deleteDataSingleLine | deleteDataMultiLine
#   revision is the count of existing file_changes for this entry at insert time,
#   giving a monotonically increasing sequence number per file.
class CreateFilesystemTables < ActiveRecord::Migration[8.1]
  def change
    create_table :directory_entries do |t|
      t.references :project,      null: false, foreign_key: true
      t.integer    :owner_id                                       # parent dir; null = root
      t.integer    :created_by_id                                  # User who created it
      t.string     :cur_name,     null: false                      # basename
      t.string     :srcpath,      null: false                      # full path within project
      t.string     :ftype,        null: false, default: 'file'     # 'file' | 'folder'
      t.timestamps
    end

    add_index :directory_entries, [:project_id, :srcpath], unique: true
    add_index :directory_entries, :owner_id

    create_table :file_changes do |t|
      t.references :directory_entry, null: false, foreign_key: true
      t.integer    :user_id                                        # nullable (system ops)
      t.string     :change_type,  null: false
      t.text       :change_data
      t.integer    :start_line,   default: 0
      t.integer    :start_char,   default: 0
      t.integer    :end_line
      t.integer    :end_char
      t.integer    :revision,     null: false, default: 0
      t.datetime   :mtime
      t.timestamps
    end

    add_index :file_changes, [:directory_entry_id, :revision]
  end
end
