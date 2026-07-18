# Tag each browser session with TWO additional build fingerprints alongside the
# human `client_version`:
#   * client_sha  — the exact git SHA of the client build that wrote the session.
#                   A discipline-free "different build?" signal: it changes on
#                   every build, so it can never silently miss a doc-shape change
#                   the way a manual version bump can. Flags which build saved the
#                   session vs. which is loading it.
#   * doc_version — the SESSION_DOC_VERSION the client stamped into the doc. Tells
#                   us whether the doc SHOULD be compatible (same shape) even when
#                   the SHA differs. Bumped only on a breaking doc-shape change.
# Both additive + nullable — legacy rows simply carry neither.
class AddClientShaAndDocVersionToBrowserSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_sessions, :client_sha, :string
    add_column :browser_sessions, :doc_version, :integer
  end
end
