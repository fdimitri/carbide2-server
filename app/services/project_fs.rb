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

  # Apply an ordered list of deltas that a client produced one after another
  # against a single local state, in one transaction. Returns the Revisions as
  # persisted (OT may have transformed or split them).
  #
  # * base_revision_id nil — each delta is a blind append at the branch head
  #   (DBFS v1 semantics; what today's client sends).
  # * base_revision_id given — the first delta is anchored to it and each later
  #   delta to the revision the previous one produced. That chain is only valid
  #   while nothing has to be transformed: once a delta is transformed past a
  #   concurrent write, the client's later coordinates no longer name any
  #   revision in the log, so the whole batch is rolled back with ConflictError
  #   rather than applied against the wrong state.
  def write_batch!(store, path, deltas, base_revision_id: nil, user_id: nil)
    return [] if deltas.empty?

    ActiveRecord::Base.transaction do
      anchor = base_revision_id
      out = []
      deltas.each_with_index do |delta, i|
        revs = store.write(path, delta, base_revision_id: anchor, user_id: user_id)
        if anchor
          transformed = revs.first.parent_id != anchor
          if transformed && i < deltas.size - 1
            raise DbfsV2::ConflictError,
                  "#{path}: change #{i} was transformed past a concurrent write; " \
                  'the rest of the batch is based on a state that no longer exists — resync'
          end
          anchor = revs.last.id
        end
        out.concat(revs)
      end
      out
    end
  end

  # Wire frame for one persisted revision, in the shape DBFS v1 clients consume:
  # ['set_contents', {content:}] for a setContents revision, else
  # ['change', {change_type:, change_data:}]. change_data is the JSON string the
  # client's applyRemoteChange parses. `revision` is now the revision UUID.
  def revision_frame(path, rev, user_id:)
    if rev.change_type == 'setContents'
      ['set_contents', { path: path, content: rev.payload['data'].to_s, revision: rev.id, user_id: user_id }]
    else
      p = rev.payload
      ['change', {
        path: path, change_type: rev.change_type, change_data: rev.change_data,
        start_line: p['startLine'], start_char: p['startChar'],
        end_line: p['endLine'], end_char: p['endChar'],
        revision: rev.id, user_id: user_id
      }]
    end
  end

  # Text content at an exact revision: from the live cache when it is at that
  # revision, else by replay. Use with head_revision_id to read a head you can
  # then anchor a write to, without racing a concurrent advance.
  def content_at(node, revision_id, branch = Branch::MAIN)
    return '' if revision_id.nil?
    DbfsV2::DocumentCache.content_at(node.id, branch, revision_id) || DbfsV2::Content.at(node, revision_id)
  end

  def head_revision_id(node, branch = Branch::MAIN)
    node = node.resolve || node
    node.branches.find_by(name: branch)&.head_revision_id
  end
end
