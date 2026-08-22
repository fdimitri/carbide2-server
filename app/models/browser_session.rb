# BrowserSession — the server-authoritative live UI/session document for one
# browser client (pane layout, focus, which surfaces are open where). The `doc`
# jsonb is an OPAQUE tree whose shape the CLIENT owns; the server only applies
# generic path patches and rebroadcasts. See future-work.md "server-side session
# tracking". A future SuperSession can group several of these across windows.
#
# Ownership model: exactly ONE producer per session (the driver) → last-write-
# wins is safe. Opening an existing session forks by default (fork_for); watching
# is a read-only WS subscription that creates no row.
require 'securerandom'

class BrowserSession < ApplicationRecord
  belongs_to :user

  # project_id is redundant in-pod (one DB per workspace) but retained as a hedge
  # for a future strip-down deploy. Default to the canonical project so callers
  # never have to supply it.
  belongs_to :project, default: -> { Project.canonical }

  # Fork-by-default lineage (self-referential). A fork is an INDEPENDENT session
  # with its own single producer, so deleting the original must NOT cascade-
  # delete diverged forks — nullify the link and let the forks survive.
  belongs_to :forked_from, class_name: 'BrowserSession', optional: true
  has_many   :forks,
             class_name:  'BrowserSession',
             foreign_key: 'forked_from_id',
             dependent:   :nullify,
             inverse_of:  :forked_from

  validates :session_uuid, presence: true, uniqueness: true

  before_validation :ensure_uuid, on: :create

  # Clone this session's document into a NEW independent session the caller
  # becomes the single producer of. Layout only — this does NOT fork the
  # filesystem (there is one shared FS view per project today).
  #
  # Faithful fork: the clone carries the same doc (deep_dup) AND the same
  # version lineage (doc_version + version_history) because its content is a
  # byte-for-byte copy of the parent. client_sha is intentionally NOT copied —
  # no write has happened on the new row yet; it is re-stamped on the fork's
  # first write.
  def fork_for(new_user)
    self.class.create!(user: new_user, project: project, name: name,
                       doc: (doc || {}).deep_dup,
                       doc_version: doc_version,
                       version_history: (version_history || []).dup,
                       forked_from: self)
  end

  # Record a write by the given SESSION_DOC_VERSION. `doc_version` is
  # last-writer-wins (replace); `version_history` is the ordered set of versions
  # that have written this doc, with sequential duplicates collapsed. Mirrors
  # the worker's write paths (session/patch + session/resync) in one place so
  # Rails and the worker can't drift.
  def record_version!(version)
    v = version.to_i
    return if v <= 0
    hist = Array(version_history).map(&:to_i)
    hist << v if hist.last != v
    self.version_history = hist
    self.doc_version = v
  end

  private

  def ensure_uuid
    self.session_uuid ||= SecureRandom.uuid
  end
end
