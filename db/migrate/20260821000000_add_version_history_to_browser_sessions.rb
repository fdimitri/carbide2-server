# Record the ordered list of SESSION_DOC_VERSIONs that have *written* this
# session's document, with sequential duplicates collapsed (so [N+5, N, N]
# becomes [N+5, N]). `doc_version` alone is last-writer-wins and cannot describe
# a chimera doc touched by multiple versions; this column does. See the
# "Session Document Versioning & Degradation" proposal and carbide2#86.
#
# A separate COLUMN, not part of the opaque doc jsonb — the server stays
# schema-agnostic about the doc while still tracking its write lineage.
class AddVersionHistoryToBrowserSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_sessions, :version_history, :jsonb, default: [], null: false
  end
end
