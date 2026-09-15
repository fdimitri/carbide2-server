> **In carbide2:** imported from `carbide2-experimental` (`dbfs_v2_prototype`,
> commit `5aa2366`). The library lives in `lib/dbfs_v2`, the models in
> `app/models`, the suite in `test/dbfs_v2`. The prototype's standalone
> sqlite bootstrap (`config/boot.rb`, `Rakefile`, `db/migrate/001..005`) is not
> carried over: carbide2 is Postgres-only, and the schema is one migration,
> `db/migrate/20260915000000_replace_dbfs_v1_with_dbfs_v2.rb`. The "Run" section
> below describes the prototype. `decisions.md` is the prototype's record, kept
> as written.

# DBFS v2 — clean-sheet prototype

A per-file **DAG** revision store for concurrent collaborative text editing,
built on Rails/Active Record (standalone, no Rails app). Every keystroke from a
client is a persistent revision; any state can be reconstructed; branches are
first-class named entities; merges are fast-forward or user-resolved; the whole
thing flushes to (and loosely syncs from) a regular filesystem.

## Run

```bash
bundle install            # or: gem install --user-install activerecord sqlite3 rb-inotify
ruby config/boot.rb       # smoke: loads everything, connects sqlite
rake db:migrate
rake test                 # or: ruby -Itest test/store_test.rb
```

## Data model

- **`file_nodes`** — one row per filesystem node: `path`, `ftype`
  (`file`/`folder`), `owner`, `posix_mode`, `symlink_target` (nil unless a
  symlink; ADR-026: a normalized DBFS path, ftype stays file/folder), `binary`
  (true for blobs — no OT, simple read/write), and `deleted_at` (tombstone; see
  **Delete** below).
- **`blobs`** — content-addressed byte store keyed by SHA-256 (`digest` PK,
  `bytea` `content`, `size`). Identical bytes across revisions/branches/projects
  share one row; a binary revision references the digest, so binary reads are
  O(1) with no replay.
- **`branches`** — first-class named branch (`main` auto-created) with a
  `head_revision_id` pointer.
- **`revisions`** — the DAG. `parent_id` (first parent), `second_parent_id`
  (non-nil ⇒ merge commit), `branch_id`, `change_type`, `change_data` (JSON),
  `user_id`, `priority` (OT tie-break), `timestamp`. UUID primary keys.
- **`keyframes`** — full-content snapshots keyed by revision, used only to skip
  replay. They never replace the log.

## Change primitives

`setContents`, `insertDataSingleLine`, `deleteDataSingleLine`,
`insertDataMultiLine`, `deleteDataMultiLine`, `replaceDataSingleLine`,
`replaceDataMultiLine`, `pcreReplaceSingleLine`, `pcreReplaceMultiLine`,
`writeBinary`. All line/char 0-based. `replace` is delete+insert at one anchor.
Content is an array of lines (trailing newline preserved).

### Binary blobs

Binary files are `FileNode`s with `binary: true`. They skip OT entirely and use
simple full-content read/write, but still flow through the same per-file DAG
(branches, fast-forward merges, revision reconstruction). Each `write_blob` is a
`writeBinary` revision whose payload is `{ sha256:, size: }` referencing the
content-addressed `blobs` table. Bytes go through the pluggable
`DbfsV2::BlobStore` seam (default: Postgres `bytea`); an S3/MinIO or Ceph backend
is a drop-in implementation of the same interface — see decisions #26/#27.

```ruby
store.create_file('/asset.bin', binary: true)
store.write_blob('/asset.bin', bytes)          # one revision (alias: import_blob)
store.read('/asset.bin')                        # => bytes (ASCII-8BIT)
store.read('/asset.bin', revision_id: rev.id)   # any revision
```

**Blob IO** (`DbfsV2::BlobIO`) is a stateless, S3-style byte interface — every op
is a pure function of `(path, revision, offset)`, and the server holds no file
descriptor (see decisions #25):

```ruby
BlobIO.read(store, '/a.bin', offset: 10, length: 64)   # range read (bytes)
BlobIO.size(store, '/a.bin')
BlobIO.digest(store, '/a.bin')                          # content address
BlobIO.put(store, '/a.bin', bytes)                      # create-or-replace
BlobIO.append(store, '/a.bin', bytes)                   # read-modify-write
BlobIO.insert(store, '/a.bin', 100, bytes)
BlobIO.overwrite(store, '/a.bin', 100, 8, bytes)
BlobIO.truncate(store, '/a.bin', 4096)
BlobIO.copy(store, '/a.bin', '/b.bin')                  # shares the digest (dedup)
```

For POSIX ergonomics there is a **client-side cursor** (no server fd state) that
pins the revision it opened and serves seek/read from it:

```ruby
cur = store.blob_cursor('/a.bin')   # pins the head revision
cur.read(4)                          # first 4 bytes
cur.seek(-4, :end); cur.read         # last 4 bytes
cur.seek(0); cur.read_all            # whole pinned content
```

The PCRE replace primitives take `{ pattern:, replacement:, limit: 0 }`:
- `limit` **0** = unlimited (like `/g`), `n` = replace the first `n` matches.
- **single-line** vs **multi-line**: single-line compiles without the `m` flag
  (`.` doesn't cross `\n`, matches are bounded to one line); multi-line enables
  it so matches may span newlines.
- `replacement` supports backreferences in Ruby (`\1`, `\k<name>`, `\0`, `\&`,
  `\\`) and PHP/preg style (`$1`, `${name}`, `$0`, `$$`).
- Replay is deterministic (the regex is re-run against the parent content).

## OT

`DbfsV2::Transform` operates over a flat character-offset space. Every delta
normalizes to primitive "splices" `(start, end, text, priority)`; insert has
`start==end`, delete has empty text, replace decomposes to `[delete, insert]`.
`transform(a, b)` returns `[a′, b′]` with `a′` the version of `a` to apply
*after* `b`. Concurrent writes that carry a stale `base_revision_id` are
transformed against the intervening revisions before append, so edits converge.
Two paths transform, and they differ for regex replaces — this is deliberate but
was previously undocumented:

- **The pairwise `Transform.transform`** (used by the unit/property suite) treats a
  pcre replace as *opaque*: on a concurrent transform it re-runs the regex against
  the merged content and records a `setContents` snapshot.
- **The live write path** (`Store#apply_transformed!`) and **merge**
  (`Merge#auto_merge_content`) instead expand a pcre replace into splices against
  the op's *base* (via `Transform.to_prims`), like any other edit. So a stale
  regex replace replaces **the instances that existed at its base**, not a
  re-run against the merged content. This is the behavior production uses;
  `transform()` is not on a production path (see decisions #20/#22).

Diffs (used to decompose `setContents` and to three-way merge) use a Myers
O(ND) algorithm (`DbfsV2::Myers`), so large files are diffed in milliseconds
rather than the old O(n·m) table. The common prefix/suffix is trimmed first;
past an edit-distance cap (`Myers::MAX_D`) a genuine full rewrite falls back to
a single coarse hunk (correct, and right for a full rewrite).

## Read acceleration (cache + auto keyframes)

Reads are O(1) in the hot path, not O(history):

- **`DbfsV2::DocumentCache`** — an in-memory live buffer per (file_node, branch),
  hydrated once from the log and advanced by each write with the same delta that
  was just persisted. `Content.head_cached` serves reads from it; a head-id
  mismatch (merge, fast-forward, external edit) makes the next read re-hydrate.
  The cache is an accelerator, never a source of truth.
- **Auto keyframes** — `Store` writes a keyframe when the cache entry crosses a
  policy threshold (`DBFS_V2_KEYFRAME_REVISIONS` default 100, or
  `DBFS_V2_KEYFRAME_BYTES` default 65536; overridable per-Store). Keyframes
  accelerate *cold* reads (replay starts from the nearest keyframe) but never
  replace the revision log.

Limitation: the auto-keyframe counter lives in the in-memory cache, so a file
that is written but never read gets no keyframe (and its first cold read after
restart replays once). Persisting "revisions since last keyframe" is the next
step if you want keyframes even for never-read files.

## Incremental dirty tracking

- `Store#dirty?(path, since:, branch:)` — O(1) `branch.head != since` check (no
  count, no walk).
- `Store#new_since(path, since_id, branch:)` — walks first-parent from the head
  back to `since_id`, bounded by the number of NEW revisions. Returns
  `[found, revs]`; `found == false` means `since_id` is stale/on another fork
  and the caller should replay from scratch.

## Merge

- **Fast-forward**: target head is an ancestor of source head → move the branch
  pointer (re-checked under the target's row lock, so a concurrent write is not
  orphaned).
- **Auto-merge** (`merge(..., auto: true)`): a three-way merge at the DAG merge
  base. Each side is diffed against the base and the source's deltas are
  OT-transformed past the target's. Overlapping writes are reported as a
  conflict (`merge_conflicts?` makes the same, diff-based check); a bug is never
  reported as a conflict.
- **User-resolved**: a merge revision with `parent_id` + `second_parent_id` and
  `setContents` carrying the resolved bytes.

## Filesystem sync

The **working area is the PVC** (local, mutable, real file IO); the **archive is
the content-addressed byte store** (`BlobStore`). The watcher applies only to the
working area.

- `DbfsV2::Flusher` writes **text** content to disk and applies POSIX mode/owner.
  It does **not** write binaries — binary bytes live in the archive and, for the
  live copy, on the PVC via ingest. (Writing them here would make the flusher a
  second writer to the authoritative working area.)
- `DbfsV2::Watcher` folds external writes back in:
  - **text** — a `setContents` revision (loose sync).
  - **binary** — routed through `DbfsV2::Ingest` (below). The read is guarded:
    the inotify watch is held, and any `IN_MODIFY` / `IN_CLOSE_WRITE` / move for
    the path during the read discards it, so the newer state is ingested. An
    intermediate state overwritten mid-read is accepted as lost. `IN_Q_OVERFLOW`
    marks the tree dirty for reconcile.

### Binary ingest — one function, two triggers

`DbfsV2::Ingest.call` is the single path that commits binary content. It copies
the source to a staging temp (hashing as it goes), **discards** if the guard saw
an event mid-read, **no-ops** if the digest equals the branch head, then moves the
staged file into the cache under its digest, puts it to the `BlobStore`, and
commits a `writeBinary` revision. The staging temp lives in the cache dir (same
filesystem, outside the watched tree), so the rename is atomic and a torn read
can never appear under a digest name.

Two triggers: a **DBFS binary write** (incl. upload) stages a temp file, renames
it into place, then calls ingest **inline**; an **external write** arrives via the
watcher. The trailing watcher event from an inline write is a no-op by digest.
The staging/cache dirs must be **outside the watched tree**.

Known limits: `mmap`'d writes are not detected and are excluded by project
policy; the watcher's visibility is local-kernel (the archive tier is unaffected).

## Delete — tombstones, never destroy

`Store#delete(path)` **soft-deletes**: it sets `deleted_at` on the node and its
whole subtree. The rows, branches and **revision DAG are preserved** — a delete
never cascades a destroy, so history is never lost. Tombstoned nodes are hidden
from `find` / `list` / `tree` / `stat` / `read` (and symlink targets resolve as
if absent).

- `store.delete('/f')` — tombstone; returns the node (nil if absent). Root cannot
  be deleted.
- `store.restore('/f')` — clear the tombstone (node + subtree).
- `store.find_any('/f')` — look up including tombstoned; `node.deleted?`
  (`FileNode.live` / `.tombstoned` scopes).
- `store.list(path, include_tombstoned: true)` and
  `store.tree(path, include_tombstoned: true)` also return soft-deleted children
  (tagged `deleted: true`), for an undelete UI.
- Re-creating a deleted path **resurrects the same node** (same id, same DAG) via
  `create_file`/`create_folder`/`create_symlink`, so history carries across a
  delete/re-create cycle — and a pre-delete revision is still readable by
  `read(path, revision_id:)`.
- The watcher routes an external `:delete` through `Store#delete` (tombstone),
  not a destroy.

```ruby
store.delete('/f')                    # tombstoned; revisions intact
store.find('/f')                      # => nil
store.find_any('/f').deleted?         # => true
store.read('/f', revision_id: old_rev)# => the pre-delete content
store.create_file('/f', content: 'x') # => SAME node id, history preserved
```

## Layout

```
app/models/   file_node.rb branch.rb revision.rb keyframe.rb blob.rb
lib/dbfs_v2/  buffer.rb delta.rb transform.rb myers.rb document_cache.rb
              content.rb merge.rb graph.rb store.rb flusher.rb watcher.rb
              blob_store.rb blob_io.rb blob_cursor.rb blob_cache.rb
              caching_blob_store.rb s3_blob_store.rb ingest.rb version.rb
db/migrate/   001..005
```
