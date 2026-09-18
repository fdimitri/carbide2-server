# ProjectFs — the carbide2 side of DBFS v2: where a project's store, working
# tree, staging area and blob cache live, plus the handful of operations that
# every consumer (Rails controllers, ArchiveImporter, FsLoader, the worker's
# FsStore / VfsWatcher / VfsFlusher / AgentTools) must do the same way.
#
# DbfsV2 itself (lib/dbfs_v2) knows nothing about Projects, Users, the PVC
# layout or the wire protocol; this module is the seam.
#
# Loaded by Rails (autoload) and by the worker (worker/ar_boot.rb).
require 'etc'
require 'fileutils'
require 'tmpdir'

module ProjectFs
  module_function

  # Largest file the loader and the watcher will bring into DBFS. Carried over
  # unchanged from DBFS v1's FsLoader::MAX_FILE_SIZE. v1 kept binary bytes on
  # the PVC only; v2 archives them in the BlobStore (Postgres bytea by default)
  # and Ingest holds the whole file in memory, so this cap now also bounds
  # worker memory and table growth. Still a constant, not a ProjectSetting — see
  # docs/dbfs_v2/decisions.md #26.
  MAX_FILE_SIZE = 5 * 1024 * 1024

  def store(project_id)
    DbfsV2::Store.new(project_id)
  end

  # The project's working tree on the PVC. Same resolution the worker has
  # always used for the flusher/watcher root.
  def root_path(project)
    File.expand_path(project.default_root_path)
  end

  # Where DBFS binary writes (uploads) stage bytes before renaming them into the
  # working tree. Must be on the same filesystem as the tree (so the rename is
  # atomic) and outside it (so the watcher never sees the temp file).
  def staging_dir(project)
    File.join(Project::PROJECTS_ROOT, '.dbfs', project.uuid.to_s, 'staging')
  end

  # Local digest-named byte cache for Ingest. Container-local and disposable:
  # a digest hit can never be stale, a miss falls through to the BlobStore.
  def blob_cache(project_id)
    @blob_caches ||= {}
    @blob_caches[project_id] ||= DbfsV2::BlobCache.new(File.join(Dir.tmpdir, "dbfs2-cache-#{project_id}"))
  end

  def binary_bytes?(bytes)
    DbfsV2::Watcher.binary_bytes?(bytes.to_s.byteslice(0, 8192))
  end

  def binary_file?(abs)
    DbfsV2::Watcher.binary_file?(abs)
  end

  # Absolute path on disk for a DBFS path, refusing anything that escapes root.
  def disk_path(root, path)
    DbfsV2::Flusher.new(nil, root).disk_path(path)
  end

  # Create a file, or return the live node already at `path`. Tolerates the
  # cross-process create race (Rails and the worker's watcher can both create
  # the same path): the loser adopts the winner's row.
  def ensure_file!(store, path, **opts)
    store.find(path) || store.create_file(path, **opts)
  rescue ActiveRecord::RecordNotUnique
    store.find(path) or raise
  end

  # mkdir -p, idempotent and race-tolerant (see ensure_file!).
  def ensure_folder!(store, path, user_id: nil)
    existing = store.find(path)
    return existing if existing&.ftype == 'folder'
    raise "not a directory: #{path}" if existing

    store.create_folder(path, user_id: user_id)
  rescue ActiveRecord::RecordNotUnique
    store.find(path) or raise
  end

  # Copy POSIX metadata from the file on disk onto the node, so a flush writes
  # the file back with the mode/owner/group it actually has (a script created
  # executable in the shell must not come back 0644, and a file owned by the
  # shell user must not be chowned to the worker's user). Owner/group are names
  # when the container's passwd/group know the id, else the numeric id string —
  # DbfsV2::Flusher resolves either. No-op when the path is gone.
  def record_disk_stat!(node, abs)
    return unless node

    st = File.lstat(abs)
    uname = (Etc.getpwuid(st.uid)&.name rescue nil) || st.uid.to_s
    gname = (Etc.getgrgid(st.gid)&.name rescue nil) || st.gid.to_s
    attrs = { posix_mode: st.mode & 0o7777, owner: uname, posix_group: gname,
              mtime: st.mtime, updated_at: Time.current }
    attrs[:last_size] = st.size if st.file?
    node.update_columns(attrs)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  # The explorer tree for a project, in one query. Wire shape is unchanged from
  # DBFS v1: { id, name, path, type, binary, symlink, children } with children
  # only on folders, folders first, then case-insensitive name. [] when the
  # project has no root yet.
  def tree_json(project_id)
    cols = %i[id parent_id cur_name path ftype binary symlink_target]
    rows = FileNode.live.where(project_id: project_id).pluck(*cols).map { |r| cols.zip(r).to_h }
    root = rows.find { |r| r[:path] == '/' }
    return [] unless root

    by_parent = rows.group_by { |r| r[:parent_id] }
    build = lambda do |r|
      node = { id: r[:id], name: r[:cur_name], path: r[:path], type: r[:ftype],
               binary: r[:binary], symlink: r[:symlink_target].present? }
      if r[:ftype] == 'folder'
        node[:children] = (by_parent[r[:id]] || [])
          .sort_by { |c| [c[:ftype] == 'folder' ? 0 : 1, c[:cur_name].to_s.downcase] }
          .map(&build)
      end
      node
    end
    build.call(root)
  end

  # The DBFS binary-write trigger (decisions #28): stage the bytes outside the
  # working tree, rename them into place, then ingest inline. The watcher's
  # trailing event for the rename is a no-op by digest. Returns the Ingest
  # result hash, or { status: :too_large } when the bytes exceed MAX_FILE_SIZE:
  # those land on disk and are tracked as a metadata-only binary node (see
  # track_oversized!), but are not archived.
  def write_binary!(project, store, path, bytes, user_id: nil)
    node = ensure_file!(store, path, binary: true, user_id: user_id)
    node = node.resolve || node
    node.update_columns(binary: true, updated_at: Time.current) unless node.binary?

    root = root_path(project)
    abs  = disk_path(root, node.path)
    stage = staging_dir(project)
    FileUtils.mkdir_p(stage)
    FileUtils.mkdir_p(File.dirname(abs))
    tmp = File.join(stage, ".upload.#{Process.pid}.#{SecureRandom.hex(8)}")
    File.binwrite(tmp, bytes.to_s.b)
    File.rename(tmp, abs)

    if bytes.to_s.bytesize > MAX_FILE_SIZE
      record_disk_stat!(node, abs)
      return { status: :too_large, size: bytes.to_s.bytesize }
    end

    res = DbfsV2::Ingest.call(
      store: store, path: node.path, source_path: abs,
      staging_dir: blob_cache(project.id).root, cache: blob_cache(project.id),
      blob_store: DbfsV2.blob_store, user_id: user_id
    )
    record_disk_stat!(node, abs)
    res
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  # A file over MAX_FILE_SIZE is tracked as a binary node with no revisions:
  # visible in the explorer, stat-able, served from disk, never archived — and,
  # because it is binary, never written back by the flusher. (Tracking it as an
  # empty text node would make the flusher truncate the real file.)
  def track_oversized!(store, path, abs, user_id: nil)
    node = ensure_file!(store, path, binary: true, user_id: user_id)
    node = node.resolve || node
    node.update_columns(binary: true, updated_at: Time.current) unless node.binary?
    record_disk_stat!(node, abs)
    node
  end

  # Outcome of write_batch!.
  #   target        the branch the batch was written to (main unless asked)
  #   mode          :blind  (no base; each delta appended at the head)
  #                 :append (base was the head; deltas appended in order)
  #                 :rebased (base was behind: auto-branched, then rebased onto target)
  #   revisions     what landed on target, as persisted, in order
  #   head          target's head afterwards
  #   old_head      target's head the batch landed on
  #   bridge        (:rebased) change hashes taking the author's state — base plus
  #                 its own batch — to `head`
  #   branch, branch_head, branch_revisions  (:rebased) the auto-branch and the
  #                 batch as authored on it
  BatchResult = Struct.new(:target, :mode, :revisions, :head, :old_head, :bridge,
                           :branch, :branch_head, :branch_revisions, keyword_init: true)

  # An anchored batch that could not be rebased onto its target. Nothing is
  # lost: the batch's revisions stay on `branch`.
  class BranchConflict < DbfsV2::ConflictError
    attr_reader :branch, :branch_head

    def initialize(message, branch:, branch_head:)
      super(message)
      @branch = branch
      @branch_head = branch_head
    end
  end

  # A base the client names that isn't reachable from the target's head (neither
  # on its first-parent chain nor the source of a rebase recorded on it).
  class UnknownBase < DbfsV2::ConflictError; end

  AUTO_BRANCH_PREFIX = 'auto/'

  # Apply an ordered list of deltas that a client (or agent) produced one after
  # another against a single local state, to `branch` (main by default).
  # Returns a BatchResult.
  #
  # * base_revision_id nil: each delta is a blind append at the branch head
  #   (DBFS v1 semantics; REST and older clients).
  # * base_revision_id == the branch head: appended in order, each anchored to the
  #   revision the previous one produced. If the head moves before the batch
  #   lands, this falls through to the auto-branch path below.
  # * base_revision_id behind the head: auto-branch. A branch
  #   ("auto/<user>/<stamp>") is forked at the base and the deltas are written
  #   to it one at a time — nothing else writes there, so none is transformed;
  #   it is the batch exactly as authored. Then the batch is rebased onto the
  #   target as operational transforms, one edit at a time (DbfsV2::Rebase): each
  #   edit is transformed past what landed since the base. Only an edit that
  #   overlaps a concurrent replace is refused (BranchConflict; the batch stays
  #   on its auto-branch). The last rebased revision records the auto-branch head
  #   as its second parent plus the bridge, so the author can keep basing edits
  #   on its own auto-branch head.
  #
  # Auto-branches are never deleted: revisions.branch_id cascades, so dropping
  # the branch row would drop the batch as authored.
  def write_batch!(store, path, deltas, base_revision_id: nil, user_id: nil, branch: Branch::MAIN)
    # The node as `branch` sees it (a project branch's index, or main's), and
    # the per-file branch its content lives under — created at the pinned
    # revision if this is the project branch's first write to the file.
    node, bname = store.locate(path, branch, for_write: true)
    raise "no such file: #{path}" unless node
    node = node.resolve || node
    head = node.branches.find_by!(name: bname).head_revision_id
    return BatchResult.new(target: bname, mode: :blind, revisions: [], head: head, old_head: head) if deltas.empty?

    if base_revision_id.nil?
      revs = ActiveRecord::Base.transaction { deltas.flat_map { |d| store.write_at(node, bname, d, user_id: user_id) } }
      return BatchResult.new(target: bname, mode: :blind, revisions: revs, head: revs.last.id, old_head: revs.first.parent_id)
    end

    if base_revision_id == head
      revs = append_anchored(store, node, deltas, base_revision_id, user_id, bname)
      return BatchResult.new(target: bname, mode: :append, revisions: revs, head: revs.last.id, old_head: base_revision_id) if revs
    end

    auto_branch_and_rebase!(store, node, path, deltas, base_revision_id, user_id, bname)
  end

  # The deltas chained from `anchor` on `branch`, in one transaction. nil (and
  # nothing committed) if the head moved first and a delta had to be transformed.
  def append_anchored(store, node, deltas, anchor, user_id, branch)
    moved = Class.new(StandardError)
    ActiveRecord::Base.transaction do
      deltas.flat_map do |delta|
        revs = store.write_at(node, branch, delta, base_revision_id: anchor, user_id: user_id)
        raise moved if revs.first.parent_id != anchor

        anchor = revs.last.id
        revs
      end
    end
  rescue moved
    nil
  end

  def auto_branch_and_rebase!(store, node, path, deltas, base, user_id, target)
    head = node.branches.find_by!(name: target).head_revision_id
    if DbfsV2::Rebase.concurrent_since(node, base, head).nil?
      raise UnknownBase, "#{path}: base revision #{base} is not in this file's history on #{target}; resync"
    end

    name = "#{AUTO_BRANCH_PREFIX}#{user_id || 'system'}/#{Time.now.utc.strftime('%Y%m%dT%H%M%S%L')}-#{SecureRandom.hex(3)}"
    store.branch_at(node, name, at_revision: base)
    authored = ActiveRecord::Base.transaction do
      deltas.flat_map { |d| store.write_at(node, name, d, user_id: user_id) }
    end
    branch_head = authored.last.id

    begin
      res = DbfsV2::Rebase.onto!(store, node, deltas.map { |d| DbfsV2::Delta.new(d.type, d.payload) },
                                 base_id: base, source_head_id: branch_head, user_id: user_id, branch: target)
    rescue DbfsV2::ConflictError => e
      raise BranchConflict.new("#{path}: #{e.message}; your edits are on branch #{name}",
                               branch: name, branch_head: branch_head)
    end

    revs = res[:revisions]
    BatchResult.new(target: target, mode: :rebased, revisions: revs, head: res[:head], old_head: revs.first.parent_id,
                    bridge: res[:bridge], branch: name, branch_head: branch_head, branch_revisions: authored)
  end

  # Wire frame for one persisted revision: ['set_contents', {content:}] for a
  # setContents revision, else ['change', {change_type:, change_data:}].
  # change_data is the JSON string the client's applyRemoteChange parses.
  # `revision` is the revision UUID; `parent` the revision it applies on top of,
  # so a client can tell whether a frame follows the state it holds.
  def revision_frame(path, rev, user_id:, branch: Branch::MAIN)
    if rev.change_type == 'setContents'
      ['set_contents', { path: path, branch: branch, content: rev.payload['data'].to_s, revision: rev.id,
                         parent: rev.parent_id, user_id: user_id }]
    else
      p = rev.payload
      ['change', {
        path: path, branch: branch, change_type: rev.change_type, change_data: rev.change_data,
        start_line: p['startLine'], start_char: p['startChar'],
        end_line: p['endLine'], end_char: p['endChar'],
        revision: rev.id, parent: rev.parent_id, user_id: user_id
      }]
    end
  end

  def change_specs(delta_hashes)
    delta_hashes.map { |h| { change_type: h[:type] || h['type'], change_data: h.reject { |k, _| k.to_s == 'type' }.to_json } }
  end

  # What the batch's author is told (fs/written). `branch` is the branch written
  # to; a rebase also names the auto-branch holding the batch as authored.
  def batch_ack(path, result, _node = nil)
    ack = { path: path, branch: result.target, mode: result.mode.to_s,
            revisions: result.revisions.map(&:id), head: result.head }
    if result.mode == :rebased
      # The author's editor holds base + its own batch (= auto_branch_head);
      # `changes` takes it to `head`.
      ack[:auto_branch] = result.branch
      ack[:auto_branch_head] = result.branch_head
      ack[:changes] = change_specs(result.bridge)
    end
    ack
  end

  # What everyone else with the file open on that branch is sent: one frame per
  # revision that landed, each chained to the one before by `parent`.
  def batch_peer_frames(path, result, _node = nil, user_id:)
    result.revisions.map { |r| revision_frame(path, r, user_id: user_id, branch: result.target) }
  end

  # Text content at an exact revision: from the live cache when it is at that
  # revision, else by replay. Use with head_revision_id to read a head you can
  # then anchor a write to, without racing a concurrent advance.
  def content_at(node, revision_id, branch = Branch::MAIN)
    return '' if revision_id.nil?
    DbfsV2::DocumentCache.content_at(node.id, branch, revision_id) || DbfsV2::Content.at(node, revision_id)
  end

  # A node found through a project branch's index (BranchFs::Node) that the
  # branch has not written yet has no per-file row: its head is the pin.
  def head_revision_id(node, branch = Branch::MAIN)
    node = node.resolve || node
    if node.respond_to?(:entry) && node.entry.content_branch_id.nil? && node.entry.project_branch&.name == branch
      return node.entry.revision_id
    end
    node.branches.find_by(name: branch)&.head_revision_id
  end
end
