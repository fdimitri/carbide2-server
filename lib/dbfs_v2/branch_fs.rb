# frozen_string_literal: true
require 'delegate'

module DbfsV2
  # BranchFs — filesystem semantics of one non-main project branch (ADR-042).
  #
  # Main's index is file_nodes (path, deleted_at, parent_id); a project branch
  # has its own in branch_entries: a full copy of the parent's live entries at
  # the fork, then its own creates/deletes/renames. Every operation here
  # records the same FileEvents Store records for main, tagged with the
  # branch, so ProjectState.at(S, P) can fold the branch's history; the
  # entries table is the branch's *current* state, as file_nodes is main's.
  #
  # Identity is shared: an entry points at a FileNode, so a file's revisions
  # and per-file branches are the same rows whichever project branch you look
  # from. A file created on a branch gets a FileNode that is NOT live on main
  # (tombstoned, with a placeholder path that cannot collide with main's
  # unique index); merging it to main gives it its real path there.
  #
  # Content on the branch, per file: `content_branch` (a per-file Branch named
  # after the project branch, bound to it) once the branch has written the
  # file; until then pinned at `revision_id`, the parent's head at the fork —
  # frozen like a git branch, not an overlay that drifts with main.
  class BranchFs
    # A FileNode as this branch sees it: the branch's path and ftype, the
    # node's everything else (id, revisions, branches, posix, symlink target).
    class Node < SimpleDelegator
      attr_reader :entry

      def initialize(record, entry, fs)
        super(record)
        @entry = entry
        @fs    = fs
      end

      def record   = __getobj__
      def path     = @entry.path
      def ftype    = @entry.ftype
      def cur_name = root? ? '/' : File.basename(@entry.path)
      def root?    = @entry.path == '/'
      def deleted? = @entry.deleted?
      def parent_path = root? ? nil : File.dirname(@entry.path)

      def resolve(seen: [], depth: 0)
        return self unless symlink?
        return nil if depth >= 40 || seen.include?(id)
        target = @fs.find(symlink_target)
        return nil unless target
        target.resolve(seen: seen + [id], depth: depth + 1)
      end

      def stat_hash
        record.stat_hash.merge(path: path, name: cur_name, type: ftype)
      end

      def reload
        @entry.reload unless @entry.new_record?
        record.reload
        self
      end

      def ==(other) = other.respond_to?(:id) && other.id == id
      alias eql? ==
      def hash = id.hash
    end

    PLACEHOLDER = '/.project-branches'

    attr_reader :store, :branch

    def initialize(store, branch)
      @store  = store
      @branch = branch
    end

    def project_id = @store.project_id

    # --- fork ---------------------------------------------------------------

    # A new project branch off `from` (a ProjectBranch), with a full copy of
    # its live entries pinned at their current content.
    def self.fork!(store, name, from:, user_id: nil)
      raise ArgumentError, "bad branch name #{name.inspect}" if name.to_s.empty? || name == ProjectBranch::MAIN
      ActiveRecord::Base.transaction do
        pb = ProjectBranch.create!(project_id: store.project_id, name: name, forked_from: from, user_id: user_id)
        pb.update_columns(fork_seq: pb.seq)
        rows = from.main? ? main_rows(store) : branch_rows(from)
        now  = Time.now.utc
        rows.each { |r| r.merge!(project_branch_id: pb.id, created_at: now, updated_at: now) }
        BranchEntry.insert_all!(rows) if rows.any?
        pb
      end
    end

    def self.main_rows(store)
      nodes = FileNode.live.where(project_id: store.project_id).where.not(path: '/').pluck(:id, :path, :ftype)
      heads = Branch.live.where(file_node_id: nodes.map(&:first), name: Branch::MAIN)
                    .pluck(:file_node_id, :head_revision_id).to_h
      nodes.map do |id, path, ftype|
        { file_node_id: id, path: path, ftype: ftype, revision_id: ftype == 'file' ? heads[id] : nil, content_branch_id: nil }
      end
    end

    def self.branch_rows(from)
      cb_heads = Branch.where(id: from.entries.live.where.not(content_branch_id: nil).select(:content_branch_id))
                       .pluck(:id, :head_revision_id).to_h
      from.entries.live.pluck(:file_node_id, :path, :ftype, :revision_id, :content_branch_id).map do |id, path, ftype, rev, cb|
        { file_node_id: id, path: path, ftype: ftype, revision_id: cb ? cb_heads[cb] : rev, content_branch_id: nil }
      end
    end

    # --- lookup ---------------------------------------------------------------

    def find(path)
      p = norm(path)
      return root_node if p == '/'
      e = live_entries.find_by(path: p)
      e && wrap(e)
    end

    def find_any(path)
      p = norm(path)
      return root_node if p == '/'
      e = @branch.entries.find_by(path: p)
      e && wrap(e)
    end

    def resolve(path)
      find(path)&.resolve
    end

    # This branch's view of a node found some other way (main's path, a merge).
    def find_by_node(node)
      e = live_entries.find_by(file_node_id: node.id)
      e && wrap(e)
    end

    def stat(path)
      node = find(path)
      return nil unless node
      target = node.resolve
      node.stat_hash.merge(symlink: node.symlink?, symlink_target: node.symlink_target, resolved_path: target&.path)
    end

    def list(path = '/', include_tombstoned: false)
      p = norm(path)
      return [] unless p == '/' || (include_tombstoned ? find_any(p) : find(p))&.ftype == 'folder'
      children_of(p, include_tombstoned).map { |e| wrap(e) }
    end

    def tree(path = '/', include_tombstoned: false)
      p = norm(path)
      node = include_tombstoned ? find_any(p) : find(p)
      return nil unless node
      scope = include_tombstoned ? @branch.entries : live_entries
      under = p == '/' ? scope.where.not(path: '/') : scope.where("path LIKE ? ESCAPE '\\'", "#{like_escape(p)}/%")
      by_parent = under.order(:path).group_by { |e| File.dirname(e.path) }
      build = lambda do |n|
        h = { id: n.id, name: n.cur_name, path: n.path, type: n.ftype, binary: n.binary?, symlink: n.symlink?,
              children: (by_parent[n.path] || []).sort_by { |e| [File.basename(e.path), e.ftype] }.map { |e| build.call(wrap(e)) } }
        h[:deleted] = n.deleted? if include_tombstoned
        h
      end
      build.call(node)
    end

    # --- existence ------------------------------------------------------------

    def create_file(path, content: '', owner: nil, group: nil, mode: 0o644, user_id: nil, binary: false)
      p = norm(path)
      node = nil
      ActiveRecord::Base.transaction do
        ensure_dir!(File.dirname(p), user_id: user_id)
        node = place!(p, ftype: 'file', owner: owner, group: group, mode: mode, binary: binary, user_id: user_id)
        if content && !content.empty?
          b = ensure_content_branch!(node)
          @store.seed_content!(node.record, b, content, binary: binary, user_id: user_id)
        end
      end
      node
    end

    def create_folder(path, owner: nil, group: nil, mode: 0o755, user_id: nil)
      p = norm(path)
      return root_node if p == '/'
      ActiveRecord::Base.transaction do
        ensure_dir!(File.dirname(p), user_id: user_id)
        place!(p, ftype: 'folder', owner: owner, group: group, mode: mode, user_id: user_id)
      end
    end

    def create_symlink(path, target, user_id: nil)
      p = norm(path)
      ActiveRecord::Base.transaction do
        ensure_dir!(File.dirname(p), user_id: user_id)
        place!(p, ftype: 'file', owner: nil, group: nil, mode: 0o777, user_id: user_id, symlink_target: norm(target))
      end
    end

    # Tombstone the entry and its subtree on this branch. Nothing else is
    # touched: the nodes, their revisions and main's view stay.
    def delete(path, user_id: nil)
      node = find(path)
      return nil unless node
      raise 'cannot delete root' if node.root?
      ActiveRecord::Base.transaction do
        rows = subtree(node.path, live_entries)
        live_entries.where(id: rows.map(&:id)).update_all(deleted_at: Time.current, updated_at: Time.current)
        Events.record!(project_id, :deleted, event_rows(rows), user_id: user_id, branch: @branch)
      end
      node.reload
    end

    def restore(path, user_id: nil)
      node = find_any(path)
      return nil unless node
      ActiveRecord::Base.transaction do
        rows = subtree(node.path, @branch.entries.tombstoned)
        rows.each { |e| raise "destination already exists: #{e.path}" if live_entries.where(path: e.path).exists? }
        @branch.entries.where(id: rows.map(&:id)).update_all(deleted_at: nil, updated_at: Time.current)
        Events.record!(project_id, :restored, event_rows(rows), user_id: user_id, branch: @branch)
      end
      node.reload
    end

    def move(from, to, user_id: nil)
      node = find(from)
      raise "no such file: #{from}" unless node
      raise 'cannot move root' if node.root?
      to_path = norm(to)
      if node.ftype == 'folder' && (to_path == node.path || to_path.start_with?("#{node.path}/"))
        raise "cannot move '#{from}' into itself"
      end
      ActiveRecord::Base.transaction do
        ensure_dir!(File.dirname(to_path), user_id: user_id)
        raise "destination already exists: #{to_path}" if live_entries.where(path: to_path).where.not(id: node.entry.id).exists?
        rows = subtree(node.path, live_entries)
        renamed = rows.map do |e|
          old_path = e.path
          new_path = e.id == node.entry.id ? to_path : "#{to_path}#{old_path.delete_prefix(node.path)}"
          # Only live paths are unique on this branch, but a stale tombstone at
          # the destination would shadow the moved node's identity for a later
          # resurrection; drop it.
          @branch.entries.tombstoned.where(path: new_path).delete_all
          e.update_columns(path: new_path, updated_at: Time.current)
          { file_node_id: e.file_node_id, from_path: old_path, ftype: e.ftype, path: new_path }
        end
        Events.record!(project_id, :renamed, renamed, user_id: user_id, branch: @branch)
      end
      node.reload
    end
    alias rename move

    # --- content --------------------------------------------------------------

    # What the branch holds for a file: its content branch's head, else the
    # pinned fork revision.
    def read(path, revision_id: nil)
      node = resolve(path)
      return nil unless node && node.ftype == 'file'
      return Content.at(node.record, revision_id) if revision_id
      e = node.entry
      return Content.head_cached(node.record, e.content_branch.name) if e.content_branch_id
      return (node.binary? ? ''.b : '') unless e.revision_id
      Content.at(node.record, e.revision_id)
    end

    # The per-file Branch this project branch writes to, created on first
    # write at the pinned revision. A live detached per-file branch of the
    # same name is adopted: the user's per-file 'feature' work is project
    # branch 'feature''s work.
    def ensure_content_branch!(node)
      e = node.entry
      return e.content_branch if e.content_branch_id
      raise "not a file: #{node.path}" unless e.ftype == 'file'
      b = ActiveRecord::Base.transaction do
        cb = node.record.branches.find_by(name: @branch.name) ||
             node.record.branches.create!(name: @branch.name, project_branch_id: @branch.id,
                                          head_revision_id: e.revision_id, origin_revision_id: e.revision_id)
        cb.update_columns(project_branch_id: @branch.id) unless cb.project_branch_id == @branch.id
        e.update_columns(content_branch_id: cb.id, updated_at: Time.current)
        cb
      end
      b
    end

    # Content pointer for ProjectState / merges: [branch_name_or_nil, revision_id].
    def content_of(node)
      e = node.entry
      e.content_branch_id ? [e.content_branch.name, e.content_branch.head_revision_id] : [nil, e.revision_id]
    end

    private

    def norm(path) = @store.send(:normalize, path)

    def live_entries = @branch.entries.live

    def root_node
      root = FileNode.find_by(project_id: project_id, path: '/') || @store.send(:ensure_root!)
      Node.new(root, BranchEntry.new(project_branch: @branch, file_node: root, path: '/', ftype: 'folder'), self)
    end

    def wrap(entry)
      Node.new(entry.file_node, entry, self)
    end

    def like_escape(s) = s.gsub('\\', '\\\\').gsub('%', '\\%').gsub('_', '\\_')

    def children_of(parent, include_tombstoned)
      scope = include_tombstoned ? @branch.entries : live_entries
      prefix = parent == '/' ? '/' : "#{parent}/"
      scope.where("path LIKE ? ESCAPE '\\'", "#{like_escape(prefix)}%")
           .where("position('/' in substr(path, ?)) = 0", prefix.length + 1)
           .where.not(path: '/')
           .order(:path)
    end

    # The entry at `path` and every descendant, within `scope`.
    def subtree(path, scope)
      scope.where("path = ? OR path LIKE ? ESCAPE '\\'", path, "#{like_escape(path)}/%").order(:path).to_a
    end

    def event_rows(entries)
      entries.map { |e| { file_node_id: e.file_node_id, path: e.path, ftype: e.ftype } }
    end

    # mkdir -p on this branch: every missing ancestor becomes a folder entry
    # (resurrected if this branch tombstoned it, else a new node).
    def ensure_dir!(path, user_id: nil)
      p = norm(path)
      return if p == '/'
      return if live_entries.where(path: p, ftype: 'folder').exists?
      ensure_dir!(File.dirname(p), user_id: user_id)
      place!(p, ftype: 'folder', owner: nil, group: nil, mode: 0o755, user_id: user_id)
    end

    # Put an entry at `path`: resurrect this branch's tombstoned entry there
    # (same identity), else a new FileNode that lives only on this branch. A
    # live entry at the path is an error.
    def place!(path, ftype:, owner:, group:, mode:, user_id:, binary: false, symlink_target: nil)
      raise "destination already exists: #{path}" if live_entries.where(path: path).exists?
      existing = @branch.entries.tombstoned.find_by(path: path)
      if existing
        existing.update_columns(deleted_at: nil, ftype: ftype, updated_at: Time.current)
        existing.file_node.update_columns(binary: binary, symlink_target: symlink_target, updated_at: Time.current) if ftype == 'file'
        node = wrap(existing.reload)
      else
        record = FileNode.create!(
          project_id: project_id,
          path: "#{PLACEHOLDER}/#{@branch.id}#{path}",
          cur_name: File.basename(path),
          ftype: ftype, binary: binary, symlink_target: symlink_target,
          owner: owner || @store.send(:default_owner), posix_group: group, posix_mode: mode,
          created_by: user_id, deleted_at: Time.current, parent_id: nil
        )
        entry = @branch.entries.create!(file_node: record, path: path, ftype: ftype)
        node = Node.new(record, entry, self)
      end
      Events.record!(project_id, :created, [{ file_node_id: node.id, path: path, ftype: ftype }],
                     user_id: user_id, branch: @branch)
      node
    end
  end
end
