# frozen_string_literal: true
module DbfsV2
  # Store — the public API. Wraps one project's file graph: filesystem
  # semantics (path/owner/perms/symlinks), the per-file DAG revision log with
  # OT on concurrent writes, first-class named branches, fast-forward and
  # user-resolved merges, and keyframe creation for replay acceleration.
  class Store
    attr_reader :project_id

    KEYFRAME_REVISIONS = Integer(ENV.fetch('DBFS_V2_KEYFRAME_REVISIONS', '100'))
    KEYFRAME_BYTES     = Integer(ENV.fetch('DBFS_V2_KEYFRAME_BYTES', '65536'))

    def initialize(project_id, keyframe_revisions: KEYFRAME_REVISIONS, keyframe_bytes: KEYFRAME_BYTES)
      @project_id = project_id
      @keyframe_revisions = keyframe_revisions
      @keyframe_bytes = keyframe_bytes
    end

    # --- filesystem --------------------------------------------------------

    def create_file(path, content: '', owner: nil, group: nil, mode: 0o644, branch: Branch::MAIN, user_id: nil, binary: false)
      if (fs = branch_fs(branch))
        return fs.create_file(path, content: content, owner: owner, group: group, mode: mode, user_id: user_id, binary: binary)
      end
      p = normalize(path)
      node = recreate_or_new(p, ftype: 'file', owner: owner, group: group, mode: mode,
                                binary: binary, user_id: user_id)
      # Create the requested branch (default 'main'); never rename an existing
      # branch. A file created on 'foo' gets a 'foo' branch, not a renamed main.
      b = node.branches.find_or_create_by!(name: branch) do |nb|
        nb.project_branch_id = main_branch.id if branch == Branch::MAIN
      end
      seed_content!(node, b, content, binary: binary, user_id: user_id) if content && !content.empty?
      node
    end

    # First content of a new file on a per-file branch row.
    def seed_content!(node, b, content, binary: false, user_id: nil)
      if binary
        write_blob_on(node, b, content, user_id: user_id)
      else
        append!(node, b, Delta.new('setContents', { data: content }), user_id: user_id)
      end
    end

    def create_folder(path, owner: nil, group: nil, mode: 0o755, user_id: nil, branch: Branch::MAIN)
      if (fs = branch_fs(branch))
        return fs.create_folder(path, owner: owner, group: group, mode: mode, user_id: user_id)
      end
      p = normalize(path)
      return ensure_root!(user_id: user_id) if p == '/'
      recreate_or_new(p, ftype: 'folder', owner: owner, group: group, mode: mode, user_id: user_id)
    end

    # Symlink: stores a normalized target DBFS path (ADR-026). The node's ftype
    # stays file/folder; writes/reads resolve through the target.
    def create_symlink(path, target, user_id: nil, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.create_symlink(path, target, user_id: user_id) if fs
      p = normalize(path)
      node = find_any(p)
      if node&.deleted?
        FileNode.transaction do
          node.update_columns(deleted_at: nil, symlink_target: normalize(target),
                              mtime: Time.current, updated_at: Time.current)
          Events.record_node!(@project_id, :created, node.reload, user_id: user_id)
        end
        return node
      end
      # mkdir -p before the transaction: its RecordNotUnique recovery must not
      # run inside a Postgres transaction it would abort.
      parent_id = ensure_dir!(File.dirname(p), user_id: user_id).id
      FileNode.transaction do
        n = FileNode.create!(
          project_id: @project_id,
          path: p,
          ftype: 'file',
          owner: default_owner,
          posix_mode: 0o777,
          symlink_target: normalize(target),
          created_by: user_id,
          parent_id: parent_id
        )
        Events.record_node!(@project_id, :created, n, user_id: user_id)
        n
      end
    end

    def find(path, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.find(path) if fs
      FileNode.live.find_by(project_id: @project_id, path: normalize(path))
    end

    # Includes tombstoned nodes. Internal (resurrect-on-create); exposed for
    # tests/tools that need to see a soft-deleted path.
    def find_any(path, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.find_any(path) if fs
      FileNode.find_by(project_id: @project_id, path: normalize(path))
    end

    # Resolve a path to the concrete node it refers to (follows symlinks).
    def resolve(path, branch: Branch::MAIN)
      node = find(path, branch: branch)
      node&.resolve
    end

    def stat(path, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.stat(path) if fs
      node = find(path)
      return nil unless node
      target = node.resolve
      node.stat_hash.merge(
        symlink:        node.symlink?,
        symlink_target: node.symlink_target,
        resolved_path:  target&.path
      )
    end

    # Immediate children of `path`, using the parent_id tree edge (indexed).
    # `include_tombstoned: true` also returns soft-deleted children (for an
    # undelete UI); they are tagged `deleted_at`.
    def list(path = '/', include_tombstoned: false, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.list(path, include_tombstoned: include_tombstoned) if fs
      parent = include_tombstoned ? find_any(path) : find(path)
      return [] unless parent
      children_scope(parent, include_tombstoned).order(:cur_name, :ftype)
    end

    # Recursive tree node (children nested), for an explorer tree view.
    def tree(path = '/', include_tombstoned: false, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.tree(path, include_tombstoned: include_tombstoned) if fs
      node = include_tombstoned ? find_any(path) : find(path)
      return nil unless node
      build_tree(node, include_tombstoned: include_tombstoned)
    end

    # Soft-delete: tombstone the node and its whole subtree. History is
    # PRESERVED — the rows, branches and revisions stay; the node is just hidden
    # (and can be restored, or resurrected by re-creating the same path). Never
    # cascades a destroy.
    def delete(path, user_id: nil, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.delete(path, user_id: user_id) if fs
      node = find(path)
      return nil unless node
      raise 'cannot delete root' if node.root?

      now = Time.current
      FileNode.transaction do
        # One operation, one seq: the subtree is gone at every cut >= it. Only
        # nodes that were live get an event; an already-tombstoned descendant
        # did not change.
        rows = event_rows(FileNode.live.where(id: tombstone_ids(node)))
        FileNode.where(id: tombstone_ids(node)).update_all(deleted_at: now, updated_at: now)
        Events.record!(@project_id, :deleted, rows, user_id: user_id)
      end
      node.reload
    end

    # Undo a delete: clear the tombstone on the node and its subtree.
    def restore(path, user_id: nil, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.restore(path, user_id: user_id) if fs
      node = find_any(path)
      return nil unless node
      FileNode.transaction do
        rows = event_rows(FileNode.tombstoned.where(id: tombstone_ids(node)))
        FileNode.where(id: tombstone_ids(node)).update_all(deleted_at: nil, updated_at: Time.current)
        Events.record!(@project_id, :restored, rows, user_id: user_id)
      end
      node.reload
    end

    # True when the project has no live entries other than the root.
    def project_empty?
      !FileNode.live.where(project_id: @project_id).where.not(path: '/').exists?
    end

    # Symlink-aware: resolves the link, so a tombstoned target reads as gone.
    # Move/rename a node. File = single-row update. Directory = rewrite the
    # descendant paths (their parent_id edges are untouched — they reference the
    # dir by id). The DAG is never touched: revisions stay keyed to the same
    # file_node_id, so history survives the move.
    def move(from, to, user_id: nil, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.move(from, to, user_id: user_id) if fs
      node = find(from)
      raise "no such file: #{from}" unless node
      raise 'cannot move root' if node.root?
      to_path = normalize(to)
      if node.ftype == 'folder' && (to_path == node.path || to_path.start_with?("#{node.path}/"))
        raise "cannot move '#{from}' into itself"
      end
      # Refuse to clobber an existing destination. Checked INSIDE the
      # transaction so a concurrent create at to_path between the check and the
      # rewrite cannot slip through (TOCTOU).
      new_parent = ensure_dir!(File.dirname(to_path), user_id: user_id)

      FileNode.transaction do
        collision = FileNode.where(project_id: @project_id, path: to_path).where.not(id: node.id).first
        raise "destination already exists: #{to_path}" if collision

        # Identity survives a move (same node id); what changes is recorded as
        # one `renamed` event per affected node under one seq — the whole
        # subtree is either moved or not at any cut. Captured before the
        # rewrite so from_path is the old path.
        renamed = FileNode.where(id: tombstone_ids(node)).pluck(:id, :path, :ftype).map do |id, old, ftype|
          { file_node_id: id, from_path: old, ftype: ftype,
            path: id == node.id ? to_path : "#{to_path}#{old.delete_prefix(node.path)}" }
        end

        if node.ftype == 'folder'
          old_prefix = "#{node.path}/"
          new_prefix = "#{to_path}/"
          # Escape LIKE metacharacters in the literal prefix (%, _, and the
          # escape char itself) so /foo%bar or /foo_bar don't match siblings,
          # but keep the trailing '%' as the wildcard.
          escaped_prefix = old_prefix.gsub('\\', '\\\\').gsub('%', '\\%').gsub('_', '\\_')
          pattern = "#{escaped_prefix}%"
          quoted = FileNode.connection.quote(new_prefix)
          FileNode.where(project_id: @project_id)
                  .where("path LIKE ? ESCAPE '\\'", pattern)
                  .update_all("path = #{quoted} || substr(path, #{old_prefix.length + 1})")
        end
        node.update_columns(
          path: to_path,
          cur_name: File.basename(to_path),
          parent_id: new_parent.id,
          mtime: Time.current,
          updated_at: Time.current
        )
        Events.record!(@project_id, :renamed, renamed, user_id: user_id)
      end
      node.reload
    end
    alias rename move

    # --- content -----------------------------------------------------------

    def read(path, revision_id: nil, branch: Branch::MAIN)
      fs = branch_fs(branch)
      return fs.read(path, revision_id: revision_id) if fs
      node = find(path)
      return nil unless node
      node = node.resolve            # self (non-symlink), target, or nil (dangling/cycle)
      return nil unless node && node.ftype == 'file'
      return Content.at(node, revision_id) if revision_id
      Content.head_cached(node, branch)
    end
    alias read_content read

    # Apply a single edit (one keystroke == one delta) to a file on a branch.
    # `base_revision_id` is the revision the client based its edit on; when it
    # is behind the branch head, the delta is OT-transformed against the
    # intervening revisions so concurrent edits converge.
    def write(path, delta, base_revision_id: nil, branch: Branch::MAIN, user_id: nil, priority: nil)
      node, bname = locate(path, branch, for_write: true)
      raise "no such file: #{path}" unless node
      raise "not a file: #{path}" unless node.ftype == 'file'
      raise "binary file: use write_blob" if node.binary?

      delta = delta.is_a?(Delta) ? delta : Delta.parse(delta['type'] || delta[:type], delta['change_data'] || delta['data'] || delta)
      raise "writeBinary is not a text edit: use write_blob" if delta.type == 'writeBinary'

      b = node.branches.find_by!(name: bname)
      write_node(node, b, delta, base_revision_id: base_revision_id, user_id: user_id, priority: priority)
    end

    # write() for a node already in hand (from locate, a branch index, or a
    # rebase/merge): no path re-resolution, so it works for a node whichever
    # project branch it was found through.
    def write_at(node, branch_name, delta, base_revision_id: nil, user_id: nil, priority: nil)
      raise "not a file: #{node.path}" unless node.ftype == 'file'
      raise "binary file: use write_blob" if node.binary?
      delta = delta.is_a?(Delta) ? delta : Delta.parse(delta['type'] || delta[:type], delta['change_data'] || delta['data'] || delta)
      b = node.branches.find_by!(name: branch_name)
      write_node(node, b, delta, base_revision_id: base_revision_id, user_id: user_id, priority: priority)
    end

    # The OT write path on a resolved node and its per-file branch row.
    def write_node(node, b, delta, base_revision_id: nil, user_id: nil, priority: nil)
      delta.priority = priority if priority
      delta.priority ||= delta.priority_for(nil)

      # Anchor the edit to the revision it is validated against: the caller's
      # base, or the head we see now for a blind append. Captured HERE so that
      # if a concurrent write moves the head before we take the lock, we
      # transform against it rather than applying stale coordinates to a newer
      # head.
      base = base_revision_id || b.head_revision_id

      # Fail closed on out-of-range client coordinates (validated against the
      # base the client claims), instead of silently clamping.
      if delta.type != 'writeBinary'
        # Validate against the content of the revision this edit is anchored to
        # (`base`) — NOT a fresh head read. Re-reading the head here would let a
        # coordinate that is only valid in a newer head pass validation, then be
        # applied against the older base (silently misplaced). `base` is nil only
        # for a blind append to an empty file, validated against empty.
        #
        # When the live cache is at exactly `base` (the normal keystroke case:
        # the editor read the file, and every write since advanced the cache),
        # its content IS Content.at(node, base) — cache_integrity_test pins that
        # equivalence — so use it instead of reloading and replaying the log.
        base_buf =
          if base.nil?
            Buffer.new('')
          else
            Buffer.new(DocumentCache.content_at(node.id, b.name, base) || Content.at(node, base))
          end
        delta.validate_against!(base_buf)
      end

      # Serialize writers on the branch row so the head read + revision insert +
      # head update are atomic. Without this, two writers that both claim
      # base == head fork off the same parent and the later update! silently
      # wins (lost update). The lock forces the loser to re-read the winner's
      # head and parent/transform against it.
      ActiveRecord::Base.transaction do
        locked = Branch.lock.find(b.id)
        if base.nil? || base == locked.head_revision_id
          [append!(node, locked, delta, user_id: user_id)]
        else
          apply_transformed!(node, locked, delta, base, user_id: user_id)
        end
      end
    end

    # Replace a binary file's content (full blob) at a branch head. No OT —
    # binary is simple read/write. Returns the new Revision.
    def write_blob(path, bytes, branch: Branch::MAIN, user_id: nil)
      node, bname = locate(path, branch, for_write: true)
      raise "no such file: #{path}" unless node
      raise "not a file: #{path}" unless node.ftype == 'file'
      raise "not a binary file: #{path}" unless node.binary?
      b = node.branches.find_by!(name: bname)
      # Same atomic head-read + insert + head-update as write(); prevents two
      # concurrent blobs from forking off the same head and losing a revision.
      ActiveRecord::Base.transaction do
        locked = Branch.lock.find(b.id)
        write_blob_on(node, locked, bytes, user_id: user_id)
      end
    end
    alias import_blob write_blob

    # A client-side cursor (fd-style seek/read) over a binary file's pinned
    # revision. The server holds no fd state. See BlobCursor / decisions #25.
    def blob_cursor(path, revision_id: nil, branch: Branch::MAIN)
      BlobCursor.new(self, path, revision_id: revision_id, branch: branch)
    end

    # --- branching / merging ----------------------------------------------

    # `at_revision:` forks the new branch at a specific revision of this file
    # instead of at `from`'s head.
    def branch(path, name, from: Branch::MAIN, at_revision: nil, branch: Branch::MAIN)
      node, = locate(path, branch, for_write: true)
      raise "no such file: #{path}" unless node
      branch_at(node, name, from: from, at_revision: at_revision)
    end

    # branch() for a node already in hand.
    def branch_at(node, name, from: Branch::MAIN, at_revision: nil)
      path = node.path
      head =
        if at_revision
          raise ActiveRecord::RecordNotFound, "revision #{at_revision} is not a revision of #{path}" unless
            Revision.exists?(id: at_revision, file_node_id: node.id)
          at_revision
        else
          node.branches.find_by!(name: from).head_revision_id
        end
      # A branch is born with a seq and its origin (ADR-042): a project state
      # cut before `seq` does not see it; one cut after it, before its first
      # commit, resolves to the origin.
      node.branches.find_or_create_by!(name: name) do |nb|
        nb.head_revision_id   = head
        nb.origin_revision_id = head
      end
    end

    def branches(path, branch: Branch::MAIN)
      node, = locate(path, branch)
      return [] unless node
      node.branches.order(:name).map { |b| { name: b.name, head: b.head_revision_id } }
    end

    # Tombstone a branch. Nothing in the file's history is touched: the row
    # stays so `revisions.branch_id` keeps meaning "the branch this was
    # committed on" (re-homing them to main would make a past project state on
    # main gain revisions that were never on main — ADR-042). Hidden from
    # FileNode#branches; the name is free for reuse. Recreate at any of its
    # revisions with branch(path, name, at_revision:).
    def delete_branch(path, name, branch: Branch::MAIN)
      raise ArgumentError, "cannot delete #{Branch::MAIN}" if name == Branch::MAIN
      node, = locate(path, branch)
      raise "no such file: #{path}" unless node
      node.branches.find_by!(name: name).tombstone!
      DocumentCache.invalidate(node.id, name)
      true
    end

    # --- project branches (ADR-042) -----------------------------------------

    def main_branch
      ProjectBranch.main_for(@project_id)
    end

    # The live project branch named `name`, or nil (main, or a name that is
    # only a detached per-file branch).
    def project_branch(name)
      return nil if name.nil? || name.to_s == Branch::MAIN
      ProjectBranch.live.find_by(project_id: @project_id, name: name.to_s)
    end

    def project_branches(include_tombstoned: false)
      scope = ProjectBranch.where(project_id: @project_id)
      scope = scope.live unless include_tombstoned
      [main_branch] + scope.where.not(name: Branch::MAIN).order(:seq, :name).to_a
    end

    # Fork a project branch off `from` (default main): a full copy of its
    # current entries, content pinned at their heads. See BranchFs.fork!.
    def create_project_branch(name, from: Branch::MAIN, user_id: nil)
      parent = from.to_s == Branch::MAIN ? main_branch : ProjectBranch.live.find_by!(project_id: @project_id, name: from.to_s)
      raise ArgumentError, "branch #{name.inspect} exists" if project_branch(name)
      BranchFs.fork!(self, name.to_s, from: parent, user_id: user_id)
    end

    # adopt! — an existing node placed at `path` on `branch` with its content
    # at `revision_id` (a project merge bringing a file the source created, or
    # renamed, onto the target with its identity intact). On main the node's
    # own row is the index: it moves from wherever it was parked (the
    # placeholder path of a branch-only file, or a tombstone) to `path`; a
    # tombstoned stranger at `path` is parked aside so the unique path index
    # holds. Content lands on the main row as a head move (FF) or a new row.
    def adopt!(record, path, branch: Branch::MAIN, ftype: nil, revision_id: nil, user_id: nil)
      fs = branch_fs(branch)
      ftype ||= record.ftype
      return fs.adopt!(record, path, ftype: ftype, revision_id: revision_id, user_id: user_id) if fs

      p = normalize(path)
      FileNode.transaction do
        parent_id = ensure_dir!(File.dirname(p), user_id: user_id).id
        clash = find_any(p)
        if clash && clash.id != record.id
          raise "destination already exists: #{p}" unless clash.deleted?
          clash.update_columns(path: "#{BranchFs::PLACEHOLDER}/tombstones/#{clash.id}", parent_id: nil, updated_at: Time.current)
        end
        record.update_columns(path: p, cur_name: File.basename(p), parent_id: parent_id, ftype: ftype,
                              deleted_at: nil, mtime: Time.current, updated_at: Time.current)
        Events.record_node!(@project_id, :created, record.reload, user_id: user_id)
        if ftype == 'file' && revision_id
          b = record.branches.find_by(name: Branch::MAIN)
          if b
            b.update!(head_revision_id: revision_id) if b.head_revision_id != revision_id
          else
            record.branches.create!(name: Branch::MAIN, project_branch_id: main_branch.id,
                                    head_revision_id: revision_id, origin_revision_id: revision_id)
          end
          DocumentCache.invalidate(record.id, Branch::MAIN)
        end
      end
      record
    end

    # Tombstone a project branch: its entries and content branches stay (a
    # past state on it still folds), the name is free for a new row.
    def delete_project_branch(name)
      raise ArgumentError, "cannot delete #{Branch::MAIN}" if name.to_s == Branch::MAIN
      pb = ProjectBranch.live.find_by!(project_id: @project_id, name: name.to_s)
      pb.tombstone!
      pb.content_branches.live.find_each { |cb| DocumentCache.invalidate(cb.file_node_id, cb.name) }
      pb
    end

    # BranchFs for a non-main project branch (by name or row), else nil: the
    # signal to take main's code path.
    def branch_fs(branch)
      pb = branch.is_a?(ProjectBranch) ? (branch.main? ? nil : branch) : project_branch(branch)
      pb && BranchFs.new(self, pb)
    end

    # The node a path names on `branch`, and the per-file branch name content
    # lives under there. On main (or a detached per-file branch name) that is
    # the path's node and the name itself. On a project branch the node comes
    # from the branch's index; with for_write the branch's content row for
    # that file is created if this is its first write.
    def locate(path, branch, for_write: false)
      fs = branch_fs(branch)
      return [resolve(path) || find(path), branch] unless fs
      node = fs.resolve(path) || fs.find(path)
      return [nil, fs.branch.name] unless node
      fs.ensure_content_branch!(node) if for_write && node.ftype == 'file'
      [node, fs.branch.name]
    end

    # A merge whose target names a project branch needs that branch's content
    # row for this file to exist (it may still be pinned at the fork).
    def ensure_project_content_branch!(node, name)
      fs = branch_fs(name)
      return unless fs
      n = fs.find_by_node(node)
      fs.ensure_content_branch!(n) if n
    end

    # --- project states (ADR-042) -------------------------------------------

    # The project clock: seq of the newest revision or filesystem event.
    def seq
      Clock.now(@project_id)
    end

    # The project's state at (seq, branch_set). Defaults to now on main.
    def state(seq: nil, branch_set: Branch::MAIN, branch: nil)
      ProjectState.at(self, seq: seq || self.seq, branch_set: BranchSet.wrap(branch_set), branch: branch)
    end

    # Name a state: store (seq, branch_set) with the manifest materialized
    # from them. The name retains it; unnamed states are just numbers.
    def snapshot!(name, seq: nil, branch_set: Branch::MAIN, user_id: nil)
      st = state(seq: seq, branch_set: branch_set)
      ProjectSnapshot.create!(
        project_id: @project_id, name: name, seq: st.seq,
        branch_set: st.branch_set.to_h.to_json, manifest: st.to_h.to_json,
        user_id: user_id, created_at: Time.now.utc
      )
    end

    def snapshots
      ProjectSnapshot.where(project_id: @project_id).order(:seq, :name)
    end

    def snapshot(name)
      ProjectSnapshot.find_by(project_id: @project_id, name: name)
    end

    # Merge project branch `source` into `target`: every file where the two
    # sets resolve to different branches is merged (fast-forward, else
    # three-way auto-merge), atomically. See ProjectMerge.
    def merge_project(target:, source:, user_id: nil)
      ProjectMerge.merge(self, target_set: BranchSet.wrap(target), source_set: BranchSet.wrap(source),
                               user_id: user_id)
    end

    # The project's branches as a rail graph (ProjectGraph.build).
    def project_graph(gap_ms: nil)
      ProjectGraph.build(self, gap_ms: gap_ms)
    end

    # Merge one project branch into its parent or the parent into it: the
    # whole tree, identity and content (ProjectMerge.branches). `dry_run`
    # previews; `resolutions` settles identity conflicts.
    def merge_branches(source:, target: Branch::MAIN, resolutions: {}, user_id: nil, dry_run: false)
      ProjectMerge.branches(self, source: source, target: target, resolutions: resolutions,
                                  user_id: user_id, dry_run: dry_run)
    end

    # Serialize the file's revision DAG (nodes + parent/second-parent edges +
    # branch heads). Read-only projection for traversal or rendering.
    def dag(path, branch: Branch::MAIN)
      Graph.dump(self, path, branch: branch)
    end

    # The DAG condensed for display: linear runs of keystrokes collapsed into
    # one node each, auto-branches folded unless `auto:`. See Graph.condense.
    def dag_condensed(path, gap_ms: nil, auto: false, branch: Branch::MAIN)
      Graph.condense(self, path, gap_ms: gap_ms, auto: auto, branch: branch)
    end

    # Graphviz DOT for `dot -Tsvg`. Merge-commit second parents are dashed.
    def dag_dot(path)
      Graph.to_dot(self, path)
    end

    # Merge `source` into `target`.
    #   auto: true            -> three-way auto-merge (conflicts surfaced)
    #   resolved: <string>    -> user-resolved merge commit with that content
    #   else                  -> fast-forward
    # `expected_head` pins the target head the caller resolved against; if the
    # target advanced since, a user-resolved merge is refused rather than
    # recording a commit whose parent silently skipped the concurrent write.
    def merge(path, target:, source:, resolved: nil, user_id: nil, auto: false, expected_head: nil,
              expected_source_head: nil, branch: Branch::MAIN)
      node, = locate(path, branch, for_write: true)
      raise "no such file: #{path}" unless node
      ensure_project_content_branch!(node, target)
      if auto
        Merge.merge_auto(node, target_name: target, source_name: source, user_id: user_id, store: self)
      elsif resolved.nil?
        Merge.fast_forward!(node, target_name: target, source_name: source, user_id: user_id)
      else
        Merge.merge_commit!(node, target_name: target, source_name: source,
                           resolved_content: resolved, user_id: user_id,
                           expected_target_head: expected_head,
                           expected_source_head: expected_source_head)
      end
    end

    # The three-way view a human resolves in: base/ours/theirs with their
    # revisions, the refused regions, and a diff3 text to start from. See
    # Merge.preview.
    def merge_preview(path, target:, source:, branch: Branch::MAIN)
      node, = locate(path, branch, for_write: true)
      raise "no such file: #{path}" unless node
      ensure_project_content_branch!(node, target)
      Merge.preview(node, target_name: target, source_name: source)
    end

    # Report whether auto-merging `source` into `target` would produce write
    # conflicts (overlapping replace/setContents edits). Returns [] if clean,
    # else an array of { target:, source: } region hashes.
    def merge_conflicts?(path, target:, source:)
      node = resolve(path) || find(path)
      raise "no such file: #{path}" unless node
      Merge.merge_conflicts?(node, target_name: target, source_name: source)
    end

    # --- keyframes ---------------------------------------------------------

    # Snapshot a branch head as a keyframe. Never deletes revisions. Binary
    # files are content-addressed (reads are already O(1)), so keyframes are a
    # no-op for them.
    def keyframe(path, branch: Branch::MAIN)
      node = resolve(path) || find(path)
      raise "no such file: #{path}" unless node
      return nil if node.binary?
      b = node.branches.find_by!(name: branch)
      raise 'branch has no head' unless b.head_revision_id
      # Idempotent: keyframing the same head twice returns the existing row
      # instead of violating the [file_node_id, revision_id] unique index.
      Keyframe.find_or_create_by!(file_node_id: node.id, revision_id: b.head_revision_id) do |kf|
        kf.content = Content.at(node, b.head_revision_id)
      end
    end

    # --- incremental dirty tracking ----------------------------------------

    # True if `branch` has any revision after `since_id` (the flusher's
    # last-flushed head). O(1): a branch head is an immutable UUID that only
    # ever advances along its first-parent chain, so it differs iff something
    # new landed. No monotonic sequence needed.
    def dirty?(path, since:, branch: Branch::MAIN)
      node = resolve(path) || find(path)
      return false unless node
      b = node.branches.find_by!(name: branch)
      b.head_revision_id && b.head_revision_id != since
    end

    # Revisions that landed on `branch` after `since_id` (exclusive), oldest-
    # first, by walking first-parent from the head back to `since_id`. The
    # look-back is bounded by the number of NEW revisions, not total history.
    #
    # Returns [found_since, revs]:
    #   found_since == true  -> `since_id` is on the head's ancestry (normal
    #                           case); `revs` is the delta to replay in order.
    #   found_since == false -> `since_id` was stale / on another fork; `revs`
    #                           is the full first-parent chain head->genesis, so
    #                           the caller should replay from scratch.
    def new_since(path, since_id, branch: Branch::MAIN)
      node = resolve(path) || find(path)
      return [false, []] unless node
      b = node.branches.find_by!(name: branch)
      head_id = b.head_revision_id
      return [true, []] if head_id.nil? || head_id == since_id

      revs = Chain.revision_index(node)
      chain = Chain.ancestor_ids(head_id, revs)   # genesis..head, inclusive
      idx = chain.index(since_id)
      if idx
        [true, chain[(idx + 1)..].map { |rid| revs[rid] }]
      else
        [false, chain.map { |rid| revs[rid] }]
      end
    end

    private

    def default_owner
      ENV.fetch('USER', 'root')
    end

    # The '/' folder node, created on first use. Tolerates a concurrent-create
    # race (falls back to the winner's row instead of raising RecordNotUnique).
    #
    # `user_id` (like ensure_dir!'s) only attributes a folder this call actually
    # creates; an existing folder keeps its created_by.
    def ensure_root!(user_id: nil)
      FileNode.find_or_create_by!(project_id: @project_id, path: '/') do |n|
        n.created_by = user_id
        n.ftype = 'folder'
        n.owner = default_owner
        n.posix_mode = 0o755
        n.cur_name = '/'
        n.parent_id = nil
      end
    rescue ActiveRecord::RecordNotUnique
      find('/')
    end

    # mkdir -p: ensure every folder along `path` exists, returning the node at
    # `path` (the root for '/'). Each segment is find-or-create with a
    # RecordNotUnique fallback, so two concurrent creators of the same
    # directory do not lose to a raw unique-index violation.
    def ensure_dir!(path, user_id: nil)
      path = normalize(path)
      return ensure_root!(user_id: user_id) if path == '/'
      cur = ensure_root!(user_id: user_id)
      current_path = ''
      path.split('/').reject(&:empty?).each do |part|
        current_path = "#{current_path}/#{part}"
        cur = find_or_create_dir!(current_path, part, cur.id, user_id: user_id)
      end
      cur
    end

    # Find-or-create a single directory segment, tolerating a concurrent create
    # (the loser re-reads the winner's row). Refuses to use a non-folder as a
    # parent, so a file cannot contain a child path.
    def find_or_create_dir!(current_path, part, parent_id, user_id: nil)
      existing = find_any(current_path)
      if existing
        # A tombstoned parent on the way to a create is resurrected, so a path
        # under a deleted directory can be reused (the dir comes back).
        if existing.deleted?
          FileNode.transaction do
            existing.update_columns(deleted_at: nil, updated_at: Time.current)
            Events.record_node!(@project_id, :restored, existing.reload, user_id: user_id)
          end
        end
        raise "not a directory: #{current_path}" unless existing.ftype == 'folder'
        return existing
      end

      # A savepoint, so the RecordNotUnique a concurrent creator provokes rolls
      # back only this insert and not a caller's enclosing transaction.
      FileNode.transaction(requires_new: true) do
        n = FileNode.create!(
          project_id: @project_id, path: current_path, ftype: 'folder',
          owner: default_owner, posix_mode: 0o755, cur_name: part, parent_id: parent_id,
          created_by: user_id
        )
        Events.record_node!(@project_id, :created, n, user_id: user_id)
        n
      end
    rescue ActiveRecord::RecordNotUnique
      find(current_path)
    end

    # FileEvent row hashes for a scope of nodes (root excluded: it always
    # exists and is not a project-state fact).
    def event_rows(scope)
      scope.where.not(path: '/').pluck(:id, :path, :ftype).map do |id, path, ftype|
        { file_node_id: id, path: path, ftype: ftype }
      end
    end

    def build_tree(node, include_tombstoned: false)
      h = {
        id: node.id, name: node.cur_name, path: node.path, type: node.ftype,
        binary: node.binary?, symlink: node.symlink?,
        children: children_scope(node, include_tombstoned)
                    .order(:cur_name, :ftype)
                    .map { |c| build_tree(c, include_tombstoned: include_tombstoned) }
      }
      h[:deleted] = node.deleted? if include_tombstoned
      h
    end

    def children_scope(node, include_tombstoned)
      include_tombstoned ? node.children : node.children.live
    end

    # Ids of a node and every descendant (by path prefix), for tombstone/
    # restore. LIKE metacharacters in the literal prefix are escaped.
    def tombstone_ids(node)
      escaped = "#{node.path}/".gsub('\\', '\\\\').gsub('%', '\\%').gsub('_', '\\_')
      FileNode.where(project_id: @project_id)
              .where("path = ? OR path LIKE ? ESCAPE '\\'", node.path, "#{escaped}%")
              .pluck(:id)
    end

    # Create a node at `path`, or RESURRECT a tombstoned one (clearing the
    # tombstone, so its revision DAG carries over). A live node at `path` is left
    # to the unique index to reject (see decisions #23).
    def recreate_or_new(path, ftype:, owner:, group:, mode:, binary: false, user_id:)
      existing = find_any(path)
      # mkdir -p before the transaction (see create_symlink).
      parent_id = ensure_dir!(File.dirname(path), user_id: user_id).id
      if existing&.deleted?
        # Resurrection is a `created` event on the same node id: the path is
        # back, with this identity (ADR-004), from this seq on.
        FileNode.transaction do
          existing.update_columns(
            deleted_at: nil, ftype: ftype,
            owner: owner || existing.owner || default_owner,
            posix_group: group, posix_mode: mode, binary: binary,
            created_by: existing.created_by || user_id,
            parent_id: parent_id,
            mtime: Time.current, updated_at: Time.current
          )
          Events.record_node!(@project_id, :created, existing.reload, user_id: user_id)
        end
        return existing
      end
      FileNode.transaction do
        n = FileNode.create!(
          project_id: @project_id, path: path, ftype: ftype,
          owner: owner || default_owner, posix_group: group, posix_mode: mode,
          created_by: user_id, binary: binary,
          parent_id: parent_id
        )
        Events.record_node!(@project_id, :created, n, user_id: user_id)
        n
      end
    end

    def normalize(path)
      p = path.to_s.strip
      p = "/#{p}" unless p.start_with?('/')
      p = p.chomp('/')
      p = '/' if p.empty?
      # Reject '.'/'..' segments: a DBFS path is a virtual, rooted path, and a
      # traversal segment would let a path escape the flush root once joined
      # onto a disk path.
      segments = p.split('/').reject(&:empty?)
      if segments.include?('.') || segments.include?('..')
        raise ArgumentError, "invalid path (contains '.' or '..'): #{path.inspect}"
      end
      "/#{segments.join('/')}"
    end

    # Append a revision and advance the branch head. `parent` is implicit (the
    # branch's current head).
    def append!(node, branch, delta, user_id: nil, second_parent_id: nil)
      parent_id = branch.head_revision_id
      rev = Revision.create!(
        file_node_id: node.id,
        project_id: @project_id,
        parent_id: parent_id,
        second_parent_id: second_parent_id,
        branch_id: branch.id,
        change_type: delta.type,
        change_data: delta.payload.to_json,
        priority: delta.priority || delta.priority_for(nil),
        user_id: user_id,
        timestamp: Time.now.utc
      )
      branch.update!(head_revision_id: rev.id)
      node.update_columns(mtime: Time.current, updated_at: Time.current)
      # Advance the in-memory cache only AFTER the surrounding transaction
      # commits, and only if the cache's head is this revision's parent (else
      # it is stale from a foreign write and is dropped). Pass parent_id so the
      # cache can make that check.
      if ActiveRecord::Base.connection.transaction_open?
        ActiveRecord.after_all_transactions_commit { advance_cache!(node, branch, rev.id, parent_id, delta) }
      else
        advance_cache!(node, branch, rev.id, parent_id, delta)
      end
      rev
    end

    # Advance the live buffer (if one exists) and write a keyframe when the
    # policy threshold is crossed. No-op for binary (digest lookup is already
    # O(1)) or for files that were never read (no cache entry to advance).
    def advance_cache!(node, branch, head_id, parent_id, delta)
      return if node.binary?
      entry = DocumentCache.advance(node.id, branch.name, head_id, parent_id, delta)
      return unless entry
      if entry.revs_since_kf >= @keyframe_revisions || entry.bytes_since_kf >= @keyframe_bytes
        # find_or_create_by! so a manual keyframe already at this head does not
        # raise RecordNotUnique when the auto threshold later fires.
        Keyframe.find_or_create_by!(file_node_id: node.id, revision_id: head_id) do |kf|
          kf.content = entry.buffer.to_s
        end
        DocumentCache.reset_keyframe_counter(node.id, branch.name)
      end
    end

    # Write a binary blob revision (content-addressed) and advance the head.
    def write_blob_on(node, branch, bytes, user_id: nil)
      bytes = bytes.to_s.b
      digest = Blob.store(bytes)
      commit_blob_revision(node, branch, digest, bytes.bytesize, user_id)
    end

    # Create a `writeBinary` revision that references an already-stored digest
    # (bytes already in the BlobStore) and advance the head. Idempotent: if the
    # branch head already references this digest, returns nil (no-op). Used by
    # the ingest path, where the bytes are stored before the revision is
    # committed.
    def commit_blob(path, digest:, size:, branch: Branch::MAIN, user_id: nil)
      node, bname = locate(path, branch, for_write: true)
      raise "no such file: #{path}" unless node
      raise "not a file: #{path}" unless node.ftype == 'file'
      raise "not a binary file: #{path}" unless node.binary?
      b = node.branches.find_by!(name: bname)
      ActiveRecord::Base.transaction do
        locked = Branch.lock.find(b.id)
        head = locked.head_revision_id && Revision.find_by(id: locked.head_revision_id)
        if head && head.change_type == 'writeBinary' && head.payload['sha256'] == digest
          next nil # no-op: head already is this content
        end
        commit_blob_revision(node, locked, digest, size, user_id)
      end
    end
    public :commit_blob

    # The digest referenced by the branch head's revision, or nil (not a binary
    # revision / no head). Used by ingest for the idempotency check.
    def head_blob_digest(path, branch: Branch::MAIN)
      node, bname = locate(path, branch)
      return nil unless node
      if (fs = branch_fs(branch)) && node.entry.content_branch_id.nil?
        head = node.entry.revision_id
      else
        b = node.branches.find_by(name: bname)
        head = b&.head_revision_id
      end
      return nil unless head
      rev = Revision.find_by(id: head)
      return nil unless rev && rev.change_type == 'writeBinary'
      rev.payload['sha256']
    end
    public :head_blob_digest

    # Low-level: append a writeBinary revision for `digest` and advance the head.
    def commit_blob_revision(node, branch, digest, size, user_id)
      rev = Revision.create!(
        file_node_id: node.id,
        project_id: @project_id,
        parent_id: branch.head_revision_id,
        second_parent_id: nil,
        branch_id: branch.id,
        change_type: 'writeBinary',
        change_data: { sha256: digest, size: size }.to_json,
        user_id: user_id,
        timestamp: Time.now.utc
      )
      branch.update!(head_revision_id: rev.id)
      node.update_columns(last_size: size, mtime: Time.current, updated_at: Time.current)
      rev
    end

    # OT path: base_revision_id is behind head. Transform the incoming delta
    # against each intervening revision in order, then append the result(s).
    # Raises if base_revision_id is not an ancestor of the branch head (the
    # client claimed an edit base that's off this branch's chain — a state
    # error we refuse to silently reconcile).
    def apply_transformed!(node, branch, delta, base_revision_id, user_id: nil)
      concurrent = revisions_between(node, base_revision_id, branch.head_revision_id)
      if concurrent.nil?
        raise "base_revision_id #{base_revision_id} is not an ancestor of branch #{branch.name} head; re-sync before writing"
      end
      state = Buffer.new(Content.at(node, base_revision_id))

      # Fold at the PRIM level: the incoming edit is a prim list in `state`'s
      # coordinate space; each concurrent revision is turned into prims in the
      # SAME space and we transform our prims past it. Prims stay in one space
      # throughout (right-to-left on apply), so a split never lands in the
      # wrong coordinate space. Encode to deltas once, at the end.
      delta.priority ||= delta.priority_for(nil)
      prims = Transform.to_prims(delta, state)

      concurrent.each do |c|
        cdelta = Delta.parse(c.change_type, c.change_data)
        cdelta.priority = c.priority || c.id
        cprims = Transform.to_prims(cdelta, state)
        # The live path has no opaque-overlap gate of its own (it folds prims
        # directly), so a replace/setContents that overlaps our edit would be
        # silently reconciled (e.g. an insert relocated to the replace's start).
        # That is the B-with-conflict rule: surface it instead.
        if Transform.ambiguous?(prims, cprims)
          raise ConflictError,
                "concurrent #{c.change_type} (rev #{c.id}) overlaps this edit; resolve manually"
        end
        prims = Transform.transform_list(prims, cprims)
        state.apply(cdelta)
      end

      Transform.deltas_for(prims, state).map do |h|
        d = Delta.new(h[:type], h.reject { |k, _| k == :type })
        d.priority = delta.priority
        append!(node, branch, d, user_id: user_id)
      end
    end

    # Revisions strictly after `base_id`, up to and including `head_id`,
    # following the first-parent chain in order (base -> head). Returns nil when
    # `base_id` is NOT on the head's ancestry (off-chain / forked base), so the
    # caller can refuse instead of silently corrupting.
    def revisions_between(node, base_id, head_id)
      return [] if base_id == head_id
      revs = Chain.revision_index(node)
      chain = Chain.ancestor_ids(head_id, revs)   # genesis..head, inclusive
      idx = chain.index(base_id)
      return nil unless idx                        # base_id off-chain
      chain[(idx + 1)..].map { |rid| revs[rid] }
    end
  end
end
