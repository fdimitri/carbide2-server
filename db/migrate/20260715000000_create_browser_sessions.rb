# Server-side "browser session" — the authoritative live UI/session document a
# client continuously syncs (pane layout, focus, which surfaces are open where).
# See future-work.md "MAJOR FEATURE: server-side session tracking".
#
# The server is a DUMB path-patch store: `doc` is an opaque JSON tree whose shape
# the CLIENT owns; the worker only applies generic [key, key, ...] -> value
# patches and rebroadcasts. We persist on every patch (plain AR save) — fine at
# carbide's per-workspace scale.
class CreateBrowserSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_sessions do |t|
      # Public/wire identity handed to clients + watchers. The sequential bigint
      # PK is never exposed on the wire; watchers reference the uuid.
      t.uuid :session_uuid, null: false

      t.references :user, null: false, foreign_key: true

      # Redundant in-pod (one logical DB per workspace) but kept as a cheap hedge
      # for a future strip-down / multi-project deploy. The model auto-fills
      # Project.canonical so callers never have to send it.
      t.references :project, null: false, foreign_key: true

      t.string :name                          # human label, nullable
      t.jsonb  :doc, null: false, default: {}  # opaque layout/session document

      # Fork-by-default open: self-referential lineage. Root (non-forked)
      # sessions have a null parent.
      t.references :forked_from,
                   foreign_key: { to_table: :browser_sessions }

      t.timestamps                             # created_at (ctime) / updated_at (mtime)
    end

    add_index :browser_sessions, :session_uuid, unique: true
  end
end
