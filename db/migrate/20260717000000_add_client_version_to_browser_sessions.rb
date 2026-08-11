# Tag each browser session with the CLIENT app version that created it
# (e.g. "0.3.1-letigre"). The session `doc` shape/semantics are owned by the
# client, so a session written by a different client build may be incompatible.
# The picker uses this to flag/disable version-mismatched sessions as garbage the
# user can delete, rather than silently resuming a doc the current build can't
# interpret. Additive + nullable — legacy rows simply have no version.
class AddClientVersionToBrowserSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_sessions, :client_version, :string
  end
end
