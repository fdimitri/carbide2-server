# Adds POSIX metadata and a binary-passthrough flag to directory_entries.
#
# Background — addresses .github/May30-Questions.md items #5/#6/#7/#13:
#   #5 stat-style file properties in the explorer pane
#   #6 store POSIX mode in DBFS
#   #7 store POSIX owner/group in DBFS
#   #13 represent binary files as DBFS entries that read straight from VFS
#
# All new columns are nullable so older entries created before this migration
# stay valid; they'll be populated by FsLoader on the next sweep.
class AddPosixAndBinaryToDirectoryEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :directory_entries, :binary,      :boolean, default: false, null: false
    add_column :directory_entries, :posix_mode,  :integer
    add_column :directory_entries, :posix_owner, :string
    add_column :directory_entries, :posix_group, :string
    add_column :directory_entries, :last_size,   :bigint
    add_column :directory_entries, :mtime,       :datetime
  end
end
