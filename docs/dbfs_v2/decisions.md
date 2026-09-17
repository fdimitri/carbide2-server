# DBFS v2 — design decisions & scale notes

## #1 — Revision log growth / write amplification

**Decision: correctness over database size. Never auto-squash.**

Every keystroke is a persistent `Revision` row, and nothing ever shrinks the
log. Keyframes only *skip replay* — they do not compact or delete history.
`Content.at` still walks ancestry and can reach every remaining revision, so
the log is always fully reconstructable and audit-able.

Rationale:

- The whole point of this store is "store every keystroke." Squashing into a
  keyframe + tail would destroy that history.
- DB size is not a concern for the intended workload; silent history loss is.

Future option (not needed now): a **side log** (1b) — batch raw keystrokes into
an append-only WAL-style log, and materialize a *compacted* revision DAG for
replay, keeping the raw keystroke log intact for audit/replay. This bounds DAG
size without losing keystrokes. Deferred until it is actually required.

Also deferred: storing revisions in a custom on-disk format instead of the DB
(a separate concern for another day).

## #6 — stat cost (revisions.count + head replay)

**Assessment: acceptable at runtime, no change needed now.**

`stat_hash` (and `store.stat`, used by the Properties panel and `fs/stat`) does:

1. `revisions.count` — one indexed `COUNT(*)` per call.
2. `content_size` — for text files this goes through `Content.head_cached`,
   which is **O(1) on a warm cache** (the in-memory `DocumentCache` buffer) and
   only replays history on a **cold** read (and then just once, populating the
   cache).

Why this is fine:

- The bulk explorer paths (`Store#tree` and `Store#list`) do **not** compute
  size or call `stat_hash` — they emit `{id, name, path, type, binary, symlink,
  children}`. So rendering a large tree does not hammer `content_size` at all.
- `stat` is called one file at a time (Properties panel / `fs/stat`), so a cold
  full-history replay happens for a single file, not a directory.

The one real caveat: `revisions.count` is still one `COUNT` query per `stat`
call. If a bulk "stat everything" path is ever added, cache `last_size` for text
(and a cached revision count) the same way binary already does. Not needed for
the current single-file stat flow.

## #7 — Auto-merge strategies & the priority problem

**Decision: auto-merge the safe cases via OT; flag overlapping "write"
(replace/setContents) edits as conflicts for a human. Never let a content-hash
priority silently choose between two people's full-region rewrites.**

We want two new merge strategies beyond fast-forward:

- `merge_auto` — replay one branch's deltas onto the other (an OT rebase),
  producing merged content with no user intervention.
- `merge_conflicts?` — report whether the two sides' changes overlap in a way
  that is semantically unsafe to auto-resolve.

The deep problem: our `priority` field is a **content hash**
(`SHA1(type + payload)`). It is deterministic and reproducible, but it is
**semantically arbitrary** — it does not encode "who is more important," "who
edited later," or "which change is better." It only provides a stable total
order so replicas converge.

That is fine for the mechanically-safe overlaps (two inserts at one cursor, an
insert vs a small delete) where both edits mostly survive and any consistent
order is acceptable. It is NOT fine when two people independently rewrite the
same region — e.g. two concurrent `replaceDataMultiLine`/`setContents` ops that
replace the same function. Picking whichever replacement hashes lower is a coin
flip that silently discards one person's intent. No priority value (content
hash, timestamp, user id, "seniority") can answer "whose function should win."

Therefore the rule (`#1` = type-based, simplest correct cut):

- **Auto-merge** when the overlap is insert/delete-scale (both edits survive;
  priority is a legitimate tie-break).
- **Conflict (surface to user)** when two concurrent ops that *write/replace*
  content (`replaceDataSingleLine`/`replaceDataMultiLine`/`setContents`) have
  intersecting regions.

A size-based refinement (conflict iff overlapping edits exceed N bytes/lines)
can layer on later without changing the model.

Implemented (see #8): `Merge.merge_auto`, `Merge.merge_conflicts?`, and a
lowest-common-ancestor helper over the DAG (`Chain`-based). `merge_commit!`
remains the human-resolution fallback.

## #8 — merge_auto / merge_conflicts? implementation notes

Implemented `Merge.merge_auto`, `Merge.merge_conflicts?`, `Merge.lowest_common_ancestor`,
and Store wrappers (`store.merge(..., auto: true)`, `store.merge_conflicts?`).

- **merge_conflicts?** — flags overlapping concurrent *write* ops
  (`replaceDataSingleLine`/`replaceDataMultiLine`/`setContents`) whose regions
  intersect. Correct: each branch's write regions are computed by replaying its
  chain from the LCA.
- **merge_auto** — fast-forwards when possible, else rejects on conflicts, else
  computes merged content and writes a `setContents` merge commit with two
  parents. (The content algorithm was later replaced by a real three-way merge
  at the DAG base — see #11; the earlier chain-flatten description here is
  historical.)

Known limitation: within-branch **sequential edits that land at the same LCA
offset** (e.g. two successive inserts at the end of the same line) are flattened
to concurrent prims and re-ordered by offset/priority, so that specific
edge case may not reproduce the branch's exact sequential byte order. Fully
general multi-commit OT rebase (inclusive transformation with composition) is a
larger piece of work, deferred. The conflict gate still prevents any *loss*; the
limitation only affects ordering of already-safe insert/delete overlaps.

## #9 — Ancestry: full DAG for merge verdicts, first-parent for replay

Two distinct walks, deliberately:

- **`Chain.reachable_ids`** — full DAG (both `parent_id` and `second_parent_id`,
  cycle-guarded). Used by `Merge.ancestors` and `Merge.lowest_common_ancestor`,
  i.e. ancestry *membership* / merge-base questions. This is what makes
  `fast_forward?` correct after a merge: a merge commit's second parent is an
  ancestor of it, so a branch already merged in can be fast-forwarded onto the
  merge commit (`test_fast_forward_onto_merge_commit_via_second_parent`).

- **`Chain.ancestor_ids`** — first-parent only, ordered genesis -> rev. This is
  the REPLAY order. Merge commits are `setContents` snapshots, so a revision's
  *content* is fully determined by the first-parent line; replay must not
  descend the second parent.

`Store#new_since` / `Store#revisions_between` use the first-parent chain because
they feed incremental replay; when the `since`/base revision is not on the
first-parent line they return `found: false` (or `nil`), signalling the caller
to replay from scratch rather than to transform against the wrong chain.

Residual limitation: `lowest_common_ancestor` is a real DAG merge base — the
common ancestor that is not itself an ancestor of another common ancestor —
so a merge commit's second parent is honoured. It returns the first such node
along a's reachable set; criss-cross histories can still have more than one
valid merge base, and this picks one deterministically rather than refusing.

## #10 — FS sync, deletion, and PCRE: known gaps

Recorded honestly; none corrupt the revision log today.

- **Flusher symlink target is a DBFS path.** `Flusher#flush_symlink` writes
  `File.symlink(node.symlink_target, abs)` where the target is the DBFS path
  (`/real`). On disk that link is broken unless something maps DBFS paths to
  the rooted path. Intentional for now (asserted in `test_flush_symlink`); a
  real flusher would rewrite the target to a path relative to the disk root.
- **Watcher delete is a hard delete, no tombstone.** `Watcher#handle` calls
  `destroy!` on `:delete` — the DAG history for that node goes with it. A
  tombstone/soft-delete (so history survives an external delete) is preferable
  but not implemented.
- **No flusher->watcher echo suppression wired up.** `Watcher#suppress!` exists
  but nothing calls it from `Flusher`, so a flush can be re-imported as an
  external edit (content-equal writes are no-ops, so it is benign today). The
  8 KiB NUL sniff and `invalid: :replace` decoding are unchanged.
- **PCRE has no timeout / ReDoS guard.** An invalid pattern raises `RegexpError`
  (fail-closed; content unchanged). A catastrophic-backtracking pattern is not
  bounded; a production path would need a match budget.

## #11 — Auto-merge is a three-way merge at the DAG base

> **Superseded in part by #29:** merges now replay the source's edits through
> `Rebase`; the three-way content merge is the fallback, and its diff no longer
> refines hunks to char splices.

`merge_auto` computes the DAG merge base, then does a real three-way merge:
diff the base against each head into prims (both in base coordinates),
OT-transform source's prims past target's, and apply both. Already-merged edits
are not present in either diff (the base is the previous source head), so
merging a branch twice does not replay them.

The diffs are **line-based multi-hunk** (`Transform.diff_prims`): lines are
tokenized with their trailing newline and LCS-diffed into hunks, then each hunk
is refined to a minimal char splice so a within-line insert stays an insert.
When the two diffs' regions overlap, `auto_merge_content` raises
`ConflictError`, which `merge_auto` turns into `{ merged: false, reason:
'conflict' }`.

Consequence: auto-merge output is a correct three-way merge, not merely
convergent. The earlier caveat (chain replay could reorder same-offset
sequential edits) is gone — that replay path was removed.

## #12 — setContents, opaque transform, and cache-vs-transaction ordering

- **setContents is diffable, not an opaque clobber** (its diff claims whole
  lines since #29). `to_prims` diffs the
  new content against the parent content (line-based multi-hunk diff) so a
  `setContents` means "these are my changes" and merges with concurrent edits.
  A genuine full rewrite degenerates to `replace [0, len) -> new`, which
  overlaps everything and is a conflict. (It was briefly a single atomic prim
  routed to the opaque snapshot path during the TP1 fixes; the diff replaced
  that — see #16.)
- **`transform_opaque` is order-independent.** (pcre is the remaining opaque
  op.) It used to apply "b then a" regardless of argument order, so
  `transform(a,b)` and `transform(b,a)` could yield different documents. It now
  applies the ops in a deterministic order (priority, tie-broken by content).
- **Cache advance moved out of the write transaction.**
  `append!` defers `advance_cache!` via
  `ActiveRecord.after_all_transactions_commit`, so a rollback can't leave the
  in-memory state advanced. `write` validates (including compiling a PCRE
  pattern) BEFORE the transaction, so a bad delta fails closed.

Test-status note: `Branch.lock` compiles to a plain `SELECT` on SQLite (the
Arel SQLite visitor drops the lock clause), so no test in this suite exercises
the row lock. The locking is correct on Postgres but **untested here** — it
needs a Postgres-backed test (or an assertion on the generated SQL). Recorded
so the green suite is not mistaken for lock coverage.

## #13 — TP1 test hardening

`assert_tp1_over` returned early on success, so the property tests executed
**zero** assertions when passing (a generator returning no ops would stay
green). It now asserts `checked > 0`. Generators extended with `setContents`
and `pcre`, and a new `test_transform_is_argument_order_independent` asserts
`transform(a,b)` and `transform(b,a)` converge to the same document.

## #14 — Tree/path races vs concurrent creates

Fixed from review:

- **`ensure_dir!` / `ensure_root!` raced on create.** Both did check-then-act
  (`find` then `create!`); two concurrent creators of the same directory made
  the loser raise `RecordNotUnique`. They now tolerate the lost race and reuse
  the winner's row (rescue `RecordNotUnique` → re-`find`). Covered by
  `TreeRaceRecoveryTest` (simulates the lost create deterministically, since
  SQLite serializes writes and cannot be raced with threads).
- **`move` collision check was outside the transaction (TOCTOU).** A create at
  `to_path` landing between the check and the descendant rewrite was clobbered.
  The collision check now runs INSIDE the `FileNode.transaction`.

Residual, not fixed:

- `move` rewrites descendants with one `update_all ... LIKE prefix%`. The
  escaping is correct, but on **SQLite** a concurrent create under the old
  prefix is not isolated against that statement the way it would be on Postgres
  with row locks. The whole-tree move takes the write transaction's lock, so a
  concurrent *write* either waits or gets `SQLITE_BUSY`, but this is not the
  same guarantee as `SELECT ... FOR UPDATE` on the parent subtree. A robust
  cross-DB version would lock the subtree (or re-verify under the same
  transaction) before the rewrite. Deferred.

## #15 — insert-inside-replace: no doubling, overlap stays opaque

`transform_ri` used to split an insert-inside-replace into two prims that BOTH
carried the replacement text (`a.text`), doubling content; `transform_rd` had
the same doubling on partial replace/delete overlap. Neither is reachable today
— `ambiguous?` routes any replace overlap (including insert-strictly-inside) to
`transform_opaque`, and boundary cases (insert at the replace's start/finish)
are handled correctly by the disjoint branches.

There is no correct prim split for the overlap case (both halves would need the
replacement text, and an insert cannot be ordered unambiguously relative to the
replacement within a single prim), which is exactly why it is opaque. The two
doubling branches are therefore replaced with a fail-loud `raise`, so that any
future narrowing of `ambiguous?` crashes instead of silently duplicating
content. Locked by `InsertInsideReplaceInvariantTest`, which also asserts the
public `transform` converges (no `RR`) via the opaque path.

## #16 — Operacy/OT fixes from the external regression suite (all green)

The external review suite (now split across `live_ot_test.rb`, `merge_edge_cases_test.rb`, `cache_integrity_test.rb`, `write_validation_test.rb`, `path_safety_test.rb`, `watcher_test.rb` — see #19) started 19 red and
is now fully green. The underlying fixes, which also resolved the remaining
"deep" items:

- **One coordinate convention.** The transform layer used two incompatible
  conventions (chained vs same-space). Now everything is same-space:
  `transform_di/dd/dr` emit post-other remnants applied right-to-left, and
  `apply_transformed!` folds at the PRIM level (no re-encode between hops).
- **Conflict gate on the live path.** `apply_transformed!` folds prims directly
  and never called `transform()`, so there was no overlap gate: a stale edit
  concurrent with a full-rewrite `setContents` was silently relocated. It now
  raises `ConflictError` when `ambiguous?` holds — the approved "B with
  conflict" semantics. `DbfsV2::ConflictError` is the typed error.
- **setContents semantics (the design call).** `setContents` is diffable and
  mergeable for non-overlapping edits; overlapping writes (full rewrite vs a
  concurrent edit) are a surfaced conflict, never a silent relocation. Position
  semantics are **positional OT**: a concurrent insert shifts a stale cursor by
  its length (a keystroke based at "end of world" lands after the inserted
  header, not re-anchored to the head).
- **Nil-base write anchoring.** `write` captures the revision the edit is
  validated against (caller base, or the head for a blind append) and uses that
  as the effective base under the lock, so a foreign write landing between
  validation and lock is transformed against rather than mis-applied. `Chain`
  reloads its associations so a foreign-written revision is visible.
- **Cache coherence.** `DocumentCache.advance` takes the revision's
  `parent_id`; if the cached head is not that parent, the entry is dropped
  (stale) rather than advancing the wrong buffer. Fixes keyframe drift under a
  cross-process write.
- **Keyframe byte threshold** compares bytes *added since the last keyframe*
  (`bytes_since_kf`), not total buffer size, so a large file no longer writes a
  keyframe on every keystroke.

## #17 — Review fixes: conflicts, rescue scope, commit re-check, cache, diff, base

Six issues found in review, all fixed:

- **Conflict detection is now diff-based, and shared.** `Merge.conflicts` diffs
  each side against the DAG merge base (`setContents` included, as a diff) and
  asks `Transform.ambiguous?`. The old version walked each branch's revision
  *list* and treated a `setContents` as rewriting the whole file, so it disagreed
  with `auto_merge_content`: it flagged a spurious conflict for a disjoint
  `setContents`+replace, and it missed insert-inside-replace. `merge_conflicts?`
  and `merge_auto` now make the SAME check and cannot disagree. The dead helpers
  (`write_regions`, `write_op?`, `regions_intersect?`, `revisions_after`) are
  removed.
- **`merge_auto` rescues only `ConflictError`.** It used to rescue
  `StandardError`, so any internal bug (e.g. `NoMethodError`) was reported to the
  caller as `reason: 'conflict'`. Now only a real conflict is; anything else
  propagates.
- **`merge_auto` re-checks the head under the commit lock.** Content is computed
  against the head read earlier; if a write lands on the target before the lock,
  committing would clobber it. The locked section now compares
  `locked.head_revision_id` to the head the content was computed from and aborts
  (`reason: 'target advanced concurrently; re-check'`) instead of overwriting.
  This mirrors the existing re-check in `fast_forward!`.
- **`DocumentCache.advance` compares head to parent unconditionally.** The old
  `e.head_id && e.head_id != parent_id` guard let a nil cached head (empty base)
  survive a foreign write: the empty buffer was advanced and the foreign content
  was dropped. `nil != parent` now invalidates the stale entry.
- **The diff is Myers O(ND), not an O(n·m) table.** `diff_hunks` used a full LCS
  table (quadratic; ~0.4 s at 2 000 lines) that fell back to a single whole-file
  hunk above ~4 M cells. It now uses `DbfsV2::Myers` (`lib/dbfs_v2/myers.rb`),
  minimal and fast for realistic edits; a pathological edit distance (a genuine
  full rewrite) returns nil and falls back to one coarse hunk, which is correct
  and right for that case. Note this feeds `setContents` prim decomposition, so
  the hunk split determines OT position semantics — it is covered by the OT
  regression suite, not just the perf test.
- **`write` validates against the anchored base, not a fresh head read.** It
  re-read the head (`head_cached`) for validation, so a foreign write landing
  mid-write could make a coordinate that is valid only in the newer head pass,
  then be applied against the older base (silently misplaced). It now validates
  against `Content.at(node, base)`, the revision the edit is anchored to (empty
  for a blind append to an empty file).

Regression tests live in `test/concurrent_edit_integrity_test.rb` (red before
the fixes, and each injection asserts it actually fired so a test cannot pass
vacuously), plus `test/diff_test.rb` for the diff itself (exact shapes,
randomized round-trip, minimality vs LCS, a pinned repeated-line tie-break, and
the scale cases — see #18).

- **`merge_commit!` (user-resolved) also re-checks the head.** It takes an
  `expected_target_head` (the head the human resolved against; defaults to the
  head read at entry) and raises `ConflictError` if the target advanced, rather
  than recording a commit whose first parent silently skipped the concurrent
  write. `Store#merge(..., resolved:, expected_head:)` threads it through.

## #18 — Diff is Myers O(ND), with a pinned tie-break

`diff_hunks` uses `DbfsV2::Myers` (`lib/dbfs_v2/myers.rb`), replacing the O(n·m)
LCS table. It trims the common token prefix/suffix first, then runs Myers on the
middle only:

- The trim is exact — any minimal edit script keeps a common prefix/suffix
  unchanged — so it is the usual fast path for real edits and collapses the
  fully-shared case (one content a suffix of the other) to a single insert.
- Myers is minimal (cost `n + m - 2·LCS`); `test/diff_test.rb` asserts that
  against a reference LCS, along with a randomized round-trip and the exact
  `diff_prims("hello\nworld", "# header\nhello\nworld") == [insert at 0]` shape.
- When the edit distance exceeds `MAX_D` (a genuine full rewrite) Myers returns
  nil and `diff_hunks` falls back to one coarse hunk — correct, and right for a
  full rewrite.

**Tie-break is a semantic choice, not an optimization.** With repeated tokens the
placement of an added token is ambiguous (all minimal). `"a\na" -> "a\na\na"` can
insert the extra `a` first, second, or third; which one is chosen decides where a
concurrent edit near the repeats lands. We pin it (`test_tie_break_with_repeated_
lines_is_pinned`): Myers appends at the END — `[[2, 2, 2, 3]]`. A future diff swap
that changes this changes OT position semantics and must fail that test loudly.

History is unaffected either way: replaying a `setContents` revision sets the
stored content and never runs the diff, so the algorithm only affects future
transforms and merges.

## #19 — Test-suite layout: properties, diff, integrity

Named by **what they protect**, not where they came from:

| File | What it is |
|------|------------|
| `tp1_test.rb` | TP1 convergence property — both application orders reach the same document (2 concurrent ops). |
| `intention_test.rb` | Intention preservation — an op's effect survives concurrent ops. (Not TP2; see #20.) |
| `diff_test.rb` | The diff itself: exact shapes, randomized round-trip, minimality vs LCS, a pinned repeated-line tie-break, and the scale/fallback cases (#18). |
| `concurrent_edit_integrity_test.rb` | "A concurrent edit is never silently lost, misapplied, or misreported" — merge conflict agreement, error propagation, no lost updates, cache coherence, validation base. |
| `live_ot_test.rb` | The live write path: split deltas, stale opaque ops, blind-append anchoring. |
| `merge_edge_cases_test.rb` | Re-merging a branch, delete-vs-replace, empty-file branches, pcre/binary merges, fast-forward not orphaning a write. |
| `cache_integrity_test.rb` | Keyframe content == full replay; the byte threshold does not keyframe every keystroke. |
| `write_validation_test.rb` | A bad delta fails closed without poisoning the file; inverted ranges rejected. |
| `path_safety_test.rb` | Traversal cannot escape the flush root; no children under a file; stat without a main branch. |
| `watcher_test.rb` | External writes absorbed faithfully: invalid UTF-8 not mangled, history survives text->binary promotion. |

Naming notes:

- Provenance ("these came from a review") is a poor name; behaviour is the right
  axis. `concurrent_edit_integrity_test.rb` was briefly `review_findings_test.rb`,
  and the old `claude_regression_test.rb` was split by subsystem into the files
  above (see #16). The review origin is still noted in each file header.
- `intention_test.rb` was briefly `tp2_test.rb`. That was wrong: TP2 is the
  3-operation convergence property, and intention preservation is a different
  thing. See #20.

**Intention preservation is scoped on purpose.** Overlapping *writes* are routed
to the conflict path by design (#7) — we do not guess intention there. So
`intention_test.rb` asserts:

- non-conflicting stale ops (insert, delete) keep their intent through
  `apply_transformed!` over multiple hops (driven through the Store, not the bare
  `transform()`, so it exercises the live path where the split-delta bug lived);
- overlapping write pairs raise `ConflictError` and commit nothing.

There is no TP2 test, deliberately — see #20.

## #20 — TP1, TP2, and intention preservation (what we test and why)

These are three different things, and only two of them apply here:

- **TP1** — the 2-operation convergence property: `apply(s, a, T(b,a)) ==
  apply(s, b, T(a,b))`. `tp1_test.rb`.
- **TP2** — the **3-operation** property (Ressel et al.): with three concurrent
  ops, `c` transformed past `a` then `b′` must equal `c` past `b` then `a′`. It
  matters when different sites transform the same op along *different* paths —
  peer-to-peer / no central serialization.
- **Intention preservation** — the "I" in CCI: each op still does what its author
  meant after concurrent ops are transformed away. `intention_test.rb`. This is
  **not** TP2.

**We do not test TP2.** Two reasons:

1. **We don't need it.** Every write serializes through the branch row lock, so
   there is one total order and each stale op is transformed along exactly one
   path — the log sequence from its base to the head. That is the Jupiter /
   Google-Docs model, where TP1 alone guarantees convergence. It holds across
   worker processes too, since they all serialize through the same Postgres row
   lock. TP2 would only be required if edits were transformed *without* that lock
   (offline editing, client-to-client, or a native client merging locally).
2. **This transform violates it.** Verified: the insert/delete pair a=insert "XX"
   at 1, b=delete [0,1), c=insert "XX" at 0 produces different `c_ab` and
   `c_ba`. (Pure insert triples happen to satisfy TP2; mixed insert/delete do
   not.) A TP2 test would be red and would send someone chasing a property this
   architecture does not need. Recorded so it is not "fixed" blindly.

**`tp2_test.rb` was misnamed and is gone.** What it actually tested was the
intention-preservation oracle, and it has been rewritten as `intention_test.rb`
with two corrections:

- **Driven through the Store**, not the bare `transform()`: commit concurrent
  revisions, then send an op with a stale base, so it exercises
  `apply_transformed!` over multiple hops (where the split-delta bug lived). The
  pairwise `transform()` is already covered by `tp1_test.rb`.
- **Overlaps assert `ConflictError`**, not the opaque snapshot. On the live path
  an overlapping write raises `ConflictError` and commits nothing — the opaque
  `setContents` that `transform()` returns is *not* the live behavior.

**Follow-up worth noting:** `Transform.transform` and its `transform_opaque`
path are not called anywhere in `lib/` — the live path (`store.rb`) and merge
(`merge.rb`) both use `transform_list` directly. `transform()` is currently
exercised only by tests. Either it is dead code to remove, or the intended public
entry point that callers moved off of; worth a decision, not changed here.

## #21 — Branch lock is a no-op on SQLite (and the tests that rely on it)

Every write and merge serializes on `Branch.lock.find(id)`. On Postgres that
emits `SELECT ... FOR UPDATE`. **On SQLite the Arel visitor drops the lock
clause**, so `Branch.lock` is a no-op there.

Consequence: the "target advanced concurrently; re-check" paths (fast-forward
re-check, `merge_auto` commit re-check, `merge_commit!` expected-head) are
exercised in the suite only through *injected* hooks, never a real race. On
SQLite they prove the code path, not the serialization.

`test/branch_lock_test.rb` makes this explicit: it asserts `FOR UPDATE` is
present when the adapter is Postgres, and **skips with that reason** on SQLite
(a structural guard also asserts `Branch.lock.find` is still used by `store.rb`
and `merge.rb`). To actually enforce the lock, run the suite on Postgres.

## #22 — Coverage added this round; and the `transform()` question

Added (driving the *production* paths, which the pairwise suite did not):

- `store_convergence_test.rb` — TP1 end to end through `apply_transformed!`:
  commit two concurrent ops in both orders and assert the same document, or both
  `ConflictError`. Covers inserts/deletes, `setContents` (diffable), and pcre
  (expanded to splices).
- `branch_lock_test.rb` — branch serialization reality (#21).
- `watcher_test.rb` — external delete wipes the node *and its DAG* (documented,
  since it is the one FS path that can destroy the log); recreate starts fresh;
  a flush echo does not duplicate a revision; a real external edit after a flush
  still imports.

Still open, not done here (recommend next, in rough priority):

- **The `transform()` question.** `Transform.transform` / `transform_opaque` /
  `encode` are not on any production path (store and merge use `transform_list`
  directly). `tp1_test.rb` therefore tests a function production never runs, and
  the two paths *differ* for pcre (opaque re-run vs base splices — now documented
  in the README). Recommended: consolidate on one entry point (make `transform()`
  a thin wrapper over the same prim fold the Store uses, or delete the unused
  path), then repoint `tp1_test.rb` at it. Left as a decision, not made
  unilaterally — which semantics should win (opaque snapshot vs splice expansion)
  is a product call.
- Real Postgres CI run (to enforce #21 rather than skip it).
- Criss-cross merge bases: `lowest_common_ancestor` picks one base
  deterministically when two are valid; add a diamond-with-cross fixture pinning
  the choice and that `merge_auto`/`merge_conflicts?` agree with it.
- Binary merge/OT edges: two `write_blob`s diverge (conflict vs LWW),
  `merge(resolved:)` on a binary node, `read(revision_id:)` after a merge commit.
- Cache vs rollback: `append!` raises before commit → cache head unchanged.
- Auto-keyframe only fires after a read (README limitation) — pin it so a future
  change is deliberate.

## #23 — Cheap contract tests added; duplicate-create wart pinned

Locked down (from the review backlog) the small FS/API contracts that had no
coverage:

- `graph_test.rb` — the **merge-commit DAG contract** the graph UI renders:
  exactly one second-parent edge, from the source head to the merge commit;
  every edge references a present node; the merge node carries the second
  parent; and the DOT export dashes exactly that edge and emits both head boxes.
- `stat_test.rb` — `stat` on a **missing path** is `nil`; **binary size** comes
  from the stored size (blob/last_size), not a replay; a **dangling symlink**
  reports `symlink: true`, its target, and `resolved_path: nil`.
- `path_safety_test.rb` — `normalize` canonicalizes `//`, trailing slashes, and
  relative/empty input to a rooted path, and rejects `.`/`..`; a **duplicate
  create** raises and does not overwrite.

**Wart pinned (not fixed):** `create_file`/`create_folder` on an existing path
leak `ActiveRecord::RecordNotUnique` (the unique index) rather than a friendlier
typed error — or returning the existing node, which the old `DirectoryEntry`
API did (`return existing if existing`). `path_safety_test.rb` pins the current
exception so any change is deliberate. Worth deciding: idempotent create
(return existing) vs a typed `AlreadyExistsError`. Not changed here because it
is a public-API semantics call.

## #24 — Tombstones: delete soft-deletes, never destroys

Grok flagged external delete as "the one FS gap that can destroy the log":
`Watcher#handle(:delete)` called `destroy!`, and `dependent: :destroy` cascaded
the revision DAG. Gone, unrecoverable. Decision: **tombstone**.

`file_nodes.deleted_at` (migration 005) marks a soft-deleted node. `Store#delete`
sets it on the node and its whole subtree (path prefix, LIKE-escaped like `move`).
Nothing is destroyed.

- **Hidden, not gone.** `find` / `list` / `tree` / `stat` / `read` filter on
  `FileNode.live`; a symlink resolving to a tombstoned target reads as dangling.
  `find_any` and the `.tombstoned` scope see it.
- **History preserved.** Revisions, branches and keyframes are untouched, so
  `read(path, revision_id:)` still reconstructs any pre-delete state.
- **Resurrect, not recreate.** Creating a path whose node is tombstoned clears
  the tombstone and reuses the SAME row (same id, same DAG) — `recreate_or_new`
  in `Store`. So a delete/re-create cycle does not fork history. The unique
  `[project_id, path]` index still holds exactly one row per path.
- **Restore.** `Store#restore` clears the tombstone on a node + subtree.
- **Watcher** routes an external `:delete` through `Store#delete`.
- Root cannot be deleted.

Deliberately deferred (noted, not built): a retention/GC pass to hard-delete
tombstones older than N (would be the only place history is ever discarded, so it
must be explicit and opt-in), and whether `list`/`tree` should optionally show
tombstones for an "undelete" UI.

## #25 — Blob IO: stateless + version-addressed; no server-side fd

"Basic POSIX read/write/seek/open for blobs" — do we emulate a file descriptor
for seek? **No.** Every blob op is a pure function of `(path, revision, offset)`:
range reads against a pinned version, whole-object writes that produce a new
content-addressed revision. For fd ergonomics there is a *client-side*
`DbfsV2::BlobCursor` (open/seek/tell/read over a pinned revision), but the server
holds no fd state. S3-style.

Why not a server fd:

- **It hides the version.** The whole model is immutable revisions + an explicit
  base. An fd is a mutable cursor that makes "which bytes am I reading?"
  implicit — exactly the thing that makes concurrent access safe to reason about.
- **It is not durable server state.** An fd must survive a reconnect, a worker
  restart, and load balancing to be useful; once you re-establish it you have
  re-implemented client state anyway.
- **It is a second coordinate system.** Text already has line/char OT with
  revision bases. A byte-offset fd would be a parallel mutable cursor that also
  has to be reconciled with concurrent edits.
- **Range reads already give streaming.** `read(offset:, length:)` against a
  pinned revision is what a seek/read loop needs, without hidden state.

`DbfsV2::BlobIO` (stateless): `read` (range), `size`, `digest`, `create`,
`write`, `put`, `append`, `insert`, `overwrite`, `truncate`, `copy`.
`Store#blob_cursor` / `DbfsV2::BlobCursor`: pinned-revision fd emulation
(seek `:set`/`:cur`/`:end`, `read`, `read_all`, `tell`, `eof?`, `close`).

Two honest notes:

- **Mutations are read-modify-write and O(size).** `append`/`insert`/`overwrite`/
  `truncate` load the blob, splice, and store a new one, so each is O(n) and a
  new content address. Content-addressed dedup means the *old* blob is not lost,
  but the new one is fully re-written. If efficient append at scale is needed,
  the fix is **content-defined chunking** (a blob is a list of chunk digests;
  append keeps the prefix chunk list) — deferred, not built.
- **Binary is last-write-wins, not OT** (unchanged from the old DBFS): two
  concurrent `write_blob`s diverge as a conflict, they do not merge.

## #26 — Blob bytes live in Postgres (bytea); that is a fork in the road

`Blob.store` binds the whole payload into a `bytea` column (migration 002). This
reverses the old DBFS, which deliberately kept binary bytes ON THE PVC with only
a pointer+size in Postgres. Trade:

- **For:** blob + revision commit in one transaction (no PG/PVC consistency
  dance), content-addressed dedup, survives pod replacement, single backup.
- **Against (real):** no size cap and no streaming — a large payload is held in a
  Ruby String and bound in one INSERT (1 GB `bytea` ceiling); incompressible
  binaries bloat the table and WAL; base backups carry them.

**Recommended hybrid** (not built): keep `blobs` as the content-addressed index
and add a `storage` discriminator — `bytea` inline below a threshold, object
storage (S3) or the PVC above it. The schema change is small.

**Regardless of where bytes live, the missing size cap is a bug:** `write_blob`
should refuse (with a clear error) above a configurable `MAX_BLOB_BYTES` before
allocating. Left open here (a one-line guard plus a decision on the limit).

## #27 — Blob bytes: `BlobStore` seam (object-API and POSIX both satisfy it)

Bytes must live somewhere **multi-node and HA**; a single ext2-4 PVC is not it.
Two families qualify and differ only in *access shape*, not in whether they can
back the store:

- **object API** — MinIO (already in the cluster) / S3 / Ceph RGW. Immutable
  put-once-read-many objects; matches the archive's access pattern directly.
- **distributed FS** — Ceph/CephFS. POSIX (open/seek/read/write), which also
  gives the mirror *direct file access*, at the cost of running a distributed FS.

So this is an **interface, not a choice**. `DbfsV2::BlobStore` is the seam:

```ruby
put(bytes)   -> sha256        # content-addressed
get(digest)  -> bytes
exist?/size/delete(digest)
read_range(digest, offset, length)   # optional native range; default slices get
```

`DbfsV2.blob_store` / `DbfsV2.with_blob_store(store)` swap the backend; every
caller (`Blob.store`, `Content#blob_content`, `BlobIO`) goes through `put`/`get`
by digest, so nothing else changes. Implementations:

- `DbBlobStore` — `blobs.content` bytea. **Default.** Transactional with the
  revision (no orphan window); right for small payloads. Supersedes #26's open
  half.
- `MemoryBlobStore` — in-memory (tests; proves the swap).
- `(future) S3BlobStore` (MinIO) and `CephBlobStore` — same interface.

Notes:

- **Content-addressing is the property that makes a swap safe:** a digest names
  exact bytes, so any backend returning those bytes for that key is correct.
  It also means a digest-keyed cache cannot be *stale* — eviction is size/time
  (LRU), but correctness is free.
- **Ordering is unchanged:** for an external backend, PUT the object, then
  commit the revision — orphans are harmless, a revision pointing at missing
  bytes is not.
- **Ceph is out of scope for the first prototype** (per Frank). The seam keeps
  it a drop-in later; the interface above is satisfiable by a POSIX backend
  (its `get`/`put`/`read_range` just hit a file).
- **Stays separate from client-serving MinIO** — a distinct bucket, so
  lifecycles and access control don't couple.

`BlobIO` write ops now uniformly return the **digest** (they previously returned
a node or a revision depending on the path).

## #28 — Binary ingest: one function, two triggers (settled)

**Layers (kept distinct):**

- **Live working area = the PVC.** Local, mutable, written in place. Real file IO
  happens here.
- **Archive = the content-addressed byte store** (`BlobStore`: Postgres `bytea`
  now, S3 or Ceph later). Immutable, digest-keyed; historical revision content
  lives here.
- Orthogonal. The watcher (inotify) applies **only to the working area**; the
  byte store is read by digest and never watched. So Ceph-as-byte-store is
  unaffected by inotify's limits. #27's Ceph option is a swap for the *archive*
  tier, not for the live file.

**One ingest function, two triggers:**

- **DBFS binary writes (including uploads)** → write a temp file on the PVC,
  rename it into place, then call ingest **inline** (not via inotify). The
  trailing watcher event is a no-op by digest.
- **External writes** → inotify → watcher → call the **same** ingest.

**Ingest is idempotent by digest:** it resolves the path to `(file, branch)` and
compares the content digest to **that branch's head**. Equal → no-op.

**Ingest read — settled (Frank's call):** read the file with the inotify watch
held. Any `IN_MODIFY` / `IN_CLOSE_WRITE` / move for that path during the read
**discards** the read, and the pending rerun ingests the newer state.
`IN_Q_OVERFLOW` marks everything dirty and rescans. **Losing an intermediate
state that was overwritten mid-read is accepted.** (`fstat` before/after and
double-read-until-stable were considered and **rejected** as the mechanism.)

**Ingest steps:** hash while copying into a local cache file → rename the cache
file to its digest **after** the clean-read check → upload to the byte store →
commit the revision.

**Cache:** local, digest-named, **outside the watched tree** (so it cannot be
re-ingested; a torn read never reaches it because rename-to-digest happens only
after the clean-read check).

**Revision inspection never writes the working tree** — it reads from the byte
store / cache. So there is **no materialize-vs-commit split**. Writing a branch's
content into its directory resolves to `(file, branch)` and is a **no-op** by the
idempotency rule (branch materialization materializes nothing new).

**Flusher stops writing binaries** (v1 already skipped them; dbfs_v2 writing
binaries was a regression). Text is still flushed.

**Limits:** `mmap`'d writes are not detected — policy is that users exclude
mmap'd files in their project. The watcher's remote-write blindness applies to the
working area, not the byte store.

## #29 — Same-line rule for snapshots; merges replay edits (Frank's call)

**Problem.** A whole-file snapshot (a `setContents`: an external change the
watcher absorbs, an agent's full-file write, a user-resolved or content merge
commit) carries no edits, so the server diffs it (`Transform.diff_prims`). A
diff is a guess and can line up differently from what happened. With hunks
refined to minimal char splices, two changes on one line could be combined into
garbled text and reported clean. Found by the client OT port's merge property
test, both confirmed in Ruby:

- base `<b.1><b.2>`: ours renames `b.1` to `o.1` (refined to replace `b`), theirs
  deletes `<b.1>` (refined to delete `1><b.`); no overlap, merged `<o.2>`;
- Myers matched a moved blank line, so theirs' insert diffed as delete
  `1><c.2><c.` plus reinsert; ours' insert landed inside it: `<c.o.1><3>`.

The same diff is used on the live path, so typing on a line while an external
tool rewrote it produced the second shape too.

**Decision (Frank chose "same line + replay branches").**

- **Snapshots claim whole lines.** `diff_prims` emits one prim per line hunk,
  not refined. A hunk that rewrites or removes lines carries `claim: :lines`
  (`:lines_eof` when it runs to the end of the text); any other change touching
  one of those lines is `ambiguous?`: a delete/replace intersecting them, or an
  insert inside them or at the start of the first (unless it adds whole lines,
  text ending in a newline). A hunk that only adds lines is an insert with
  `claim: :before`: it touches no line, and at a tie goes before any other
  insert (a plain insert there meant the start of the old line). Edits on other
  lines still merge.
- **Merges replay edits.** `merge_auto` rebases the source's first-parent
  revisions since the merge base onto the target (`Rebase.compute`), as the
  live path does, and commits them as linear revisions; the last one is the
  merge commit (second parent = source head) and stores the bridge, so merging
  the same branch again finds its base through the bridge. Edits on the same
  line of two branches merge. A snapshot in the source's history is diffed
  when replayed, so it follows the same-line rule.
- **Content merge is the fallback,** when the source has no first-parent path
  from the merge base (it merged the target in). It keeps the one-commit
  `setContents` merge and the same-line rule.
- `merge_conflicts?` runs the same computation as `merge_auto` on either path,
  so they agree; a replay conflict reports the two regions as before
  (`OverlapConflict#regions`).

**Costs.** More conflicts where a snapshot is involved: an external rewrite of a
line someone is typing on is refused on the live path (the watcher's existing
conflict handling: logged, not applied), and two snapshots touching one line
conflict. A merge commit is no longer always a `setContents`.

Tests: `same_line_rule_test.rb` (the rule, both garbling cases, the live path,
replayed merges, the content fallback, and a random property over real-edit
and snapshot branches); the client OT port mirrors it and
`tests/parity` checks the two agree.

