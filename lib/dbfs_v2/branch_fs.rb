# frozen_string_literal: true
require 'delegate'
require 'set'

module DbfsV2
  # BranchFs — filesystem semantics of one project branch, including main.
  # Every public path op appends one running project-DAG node and moves HEAD
  # onto it. The running head is the live tree: path → identity, content a
  # live line (submodule→branch). There is no dirty working tree.
  #
  # FileNode is identity (uuid, posix, content DAG); its path column is a
  # unique slot, not the user-visible location. FileEvents are notifications
  # (explorer / seq clock), not the source of the tree: they reuse the
  # project node's seq so a cut S names the tree and the notifications.
  class BranchFs
    # A FileNode as this branch sees it: the project's path and ftype, the
    # node's everything else (id, revisions, branches, posix, symlink target).
    class Node < SimpleDelegator
      attr_reader :entry, :source_node

      def initialize(record, entry, fs, deleted: false, source_node: nil)
        super(record)
        @entry       = entry
        @fs          = fs
        @deleted     = deleted
        @source_node = source_node
      end

      def record   = __getobj__
      def path     = @entry.path
      def ftype    = @entry.ftype
      def cur_name = root? ? '/' : File.basename(@entry.path)
      def root?    = @entry.path == '/'
      def deleted? = @deleted
      def parent_path = root? ? nil : File.dirname(@entry.path)
      def parent      = root? ? nil : @fs.find(parent_path)
      def parent_id   = parent&.id

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
        fresh = @fs.find_by_id(id) || @fs.find_any_by_id(id)
        if fresh
          @entry       = fresh.entry
          @deleted     = fresh.deleted?
          @source_node = fresh.source_node
        end
        record.reload
        self
      end

      def ==(other) = other.respond_to?(:id) && other.id == id
      alias eql? ==
      def hash = id.hash
    end

    RootEntry = Struct.new(:path, :ftype, :file_node_id, :content_branch_id, :revision_id, :file_node,
                           keyword_init: true) do
      def deleted? = false
      def folder? = true
      def root? = true
      def content_branch = nil
      def project_branch = nil
    end

    # FileNode.path is a unique identity slot, not a branch location.
    IDENTITY_PREFIX = '/.nodes'
    PLACEHOLDER = IDENTITY_PREFIX

    attr_reader :store, :branch

    def initialize(store, branch)
      @store  = store
      @branch = branch
    end

    def project_id = @store.project_id

    # --- fork ---------------------------------------------------------------

    # A new project branch off `from`. Each file gets a new content line at
    # the parent's current head — a new line, not a shared pointer that
    # drifts with the parent.
    def self.fork!(store, name, from:, user_id: nil)
      raise ArgumentError, "bad branch name #{name.inspect}" if name.to_s.empty? || name == ProjectBranch::MAIN
      ActiveRecord::Base.transaction do
        pb = ProjectBranch.create!(project_id: store.project_id, name: name, forked_from: from, user_id: user_id)
        pb.update_columns(fork_seq: pb.seq, base_seq: pb.seq, base_branch_id: from.id)
        src_head = from.head_node
        if src_head
          ProjectDag.flatten(src_head).each do |e|
            next unless e.ftype == 'file'
            at = e.content_branch&.head_revision_id || e.revision_id
            mint_fork_line!(e.file_node, pb, at)
          end
          # Share the parent's running trees. Content is the new lines
          # resolved by (file_node, this project branch), not stored on the tree.
          ProjectDag.insert!(pb, parent: src_head, kind: ProjectNode::RUNNING,
                             root_tree_id: src_head.root_tree_id, user_id: user_id)
          pb.reload
        end
        cut = src_head && ProjectDag.freeze!(from)
        pb.update_columns(fork_node_id: cut&.id, base_node_id: cut&.id, updated_at: Time.current)
        pb
      end
    end

    def self.mint_fork_line!(record, pb, at)
      existing = record.branches.find_by(name: pb.name)
      existing.tombstone! if existing
      record.branches.create!(name: pb.name, project_branch_id: pb.id,
                              head_revision_id: at, origin_revision_id: at)
    end

    # --- lookup ---------------------------------------------------------------

    def find(path)
      p = norm(path)
      return root_node(create: false) if p == '/'
      e = head_lookup(p)
      e && wrap(e, source_node: current_head)
    end

    def find_any(path)
      p = norm(path)
      return root_node(create: false) if p == '/'
      if (e = head_lookup(p))
        return wrap(e, source_node: tip_node)
      end
      ghost = ancestor_entry_by_path(p)
      ghost && wrap(ghost[:entry], deleted: true, source_node: ghost[:node])
    end

    def find_any_by_id(id)
      if (e = head_lookup_id(id))
        return wrap(e, source_node: tip_node)
      end
      ghost = ancestor_entry_by_id(id)
      ghost && wrap(ghost[:entry], deleted: true, source_node: ghost[:node])
    end

    def resolve(path)
      find(path)&.resolve
    end

    def find_by_node(node)
      find_by_id(node.id)
    end

    def find_by_id(id)
      e = head_lookup_id(id)
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
      listed_children(p, include_tombstoned: include_tombstoned)
    end

    def tree(path = '/', include_tombstoned: false)
      p = norm(path)
      node = include_tombstoned ? find_any(p) : find(p)
      return nil unless node
      entries, deleted_ids = index_for_tree(node, include_tombstoned: include_tombstoned)
      by_parent = entries.reject { |e| e.path == '/' }.group_by { |e| File.dirname(e.path) }
      build = lambda do |n|
        h = { id: n.id, name: n.cur_name, path: n.path, type: n.ftype, binary: n.binary?, symlink: n.symlink? }
        if n.ftype == 'folder'
          kids = (by_parent[n.path] || []).sort_by { |e| [e.ftype == 'folder' ? 0 : 1, File.basename(e.path).downcase] }
          h[:children] = kids.map { |e| build.call(wrap(e, deleted: deleted_ids.include?(e.file_node_id))) }
        end
        h[:deleted] = n.deleted? if include_tombstoned
        h
      end
      build.call(node)
    end

    # --- existence ------------------------------------------------------------

    def create_file(path, content: '', owner: nil, group: nil, mode: 0o644, user_id: nil, binary: false,
                    bind_content: true)
      p = norm(path)
      node = nil
      ActiveRecord::Base.transaction do
        lock_tip!
        root_node(user_id: user_id)
        pending = []
        collect_missing_dirs!(File.dirname(p), pending, user_id)
        raise "destination already exists: #{p}" if live_path?(p, pending)
        record, cb = place_file!(p, pending, owner: owner, group: group, mode: mode,
                                 user_id: user_id, binary: binary, bind_content: bind_content)
        if bind_content && cb && content && !content.empty?
          @store.seed_content!(record, cb, content, binary: binary, user_id: user_id)
        end
        n = commit_path_op!(add: pending, user_id: user_id)
        Events.record!(project_id, :created, event_rows_from(pending), user_id: user_id, branch: @branch, seq: n.seq)
        node = find(p)
      end
      node
    end

    def create_folder(path, owner: nil, group: nil, mode: 0o755, user_id: nil)
      p = norm(path)
      return root_node(user_id: user_id) if p == '/'
      ActiveRecord::Base.transaction do
        lock_tip!
        root_node(user_id: user_id)
        pending = []
        collect_missing_dirs!(File.dirname(p), pending, user_id)
        raise "destination already exists: #{p}" if live_path?(p, pending)
        collect_missing_dirs!(p, pending, user_id, owner: owner, group: group, mode: mode)
        n = commit_path_op!(add: pending, user_id: user_id)
        Events.record!(project_id, :created, event_rows_from(pending), user_id: user_id, branch: @branch, seq: n.seq)
        find(p)
      end
    end

    def create_symlink(path, target, user_id: nil)
      p = norm(path)
      ActiveRecord::Base.transaction do
        lock_tip!
        root_node(user_id: user_id)
        pending = []
        collect_missing_dirs!(File.dirname(p), pending, user_id)
        raise "destination already exists: #{p}" if live_path?(p, pending)
        place_file!(p, pending, owner: nil, group: nil, mode: 0o777,
                    user_id: user_id, binary: false, bind_content: true,
                    symlink_target: norm(target))
        n = commit_path_op!(add: pending, user_id: user_id)
        Events.record!(project_id, :created, event_rows_from(pending), user_id: user_id, branch: @branch, seq: n.seq)
        find(p)
      end
    end

    # Drop the path (and its subtree) from HEAD. Identity and the content
    # DAG stay; restore / re-create walk parents to put the UUID back.
    def delete(path, user_id: nil)
      node = find(path)
      return nil unless node
      raise 'cannot delete root' if node.root?
      ActiveRecord::Base.transaction do
        lock_tip!
        rows = subtree(node.path)
        n = commit_path_op!(remove_paths: [node.path], user_id: user_id)
        Events.record!(project_id, :deleted, event_rows(rows), user_id: user_id, branch: @branch, seq: n.seq)
      end
      find_any(path)
    end

    def restore(path, user_id: nil)
      node = find_any(path)
      return nil unless node
      return node unless node.deleted?
      ActiveRecord::Base.transaction do
        lock_tip!
        raise "destination already exists: #{node.path}" if head_lookup(node.path)
        src = node.source_node
        raise "cannot restore #{path}: no ancestor" unless src
        top = ProjectDag.lookup(src, node.path)
        raise "cannot restore #{path}: no ancestor" unless top
        rows = ProjectDag.subtree(src, node.path)
        live_ids = head_id_set
        pending = []
        collect_missing_dirs!(File.dirname(node.path), pending, user_id)
        clash = rows.find { |e| live_ids.include?(e.file_node_id) && e.file_node_id != top.file_node_id }
        if top.ftype == 'folder' && clash.nil?
          raise "destination already exists: #{top.path}" if live_path?(top.path, pending)
          pending << { file_node_id: top.file_node_id, path: top.path, ftype: top.ftype,
                       child_tree_id: top.child_tree_id }
        else
          rows.each do |e|
            next if live_ids.include?(e.file_node_id)
            raise "destination already exists: #{e.path}" if live_path?(e.path, pending)
            pending << { file_node_id: e.file_node_id, path: e.path, ftype: e.ftype }
          end
        end
        n = commit_path_op!(add: pending, user_id: user_id)
        Events.record!(project_id, :restored, event_rows(rows.reject { |e| live_ids.include?(e.file_node_id) }),
                       user_id: user_id, branch: @branch, seq: n.seq)
      end
      find(path)
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
        lock_tip!
        pending = []
        collect_missing_dirs!(File.dirname(to_path), pending, user_id)
        clash = head_lookup(to_path)
        raise "destination already exists: #{to_path}" if clash && clash.file_node_id != node.id
        rows = subtree(node.path)
        # Descendants ride the reused child tree; only the moved node is rewritten.
        rewrite = { node.id => { path: to_path } }
        renamed = rows.map do |e|
          old_path = e.path
          new_path = e.file_node_id == node.id ? to_path : "#{to_path}#{old_path.delete_prefix(node.path)}"
          { file_node_id: e.file_node_id, from_path: old_path, ftype: e.ftype, path: new_path }
        end
        n = commit_path_op!(add: pending, rewrite: rewrite, user_id: user_id)
        Events.record!(project_id, :created, event_rows_from(pending), user_id: user_id, branch: @branch, seq: n.seq) if pending.any?
        Events.record!(project_id, :renamed, renamed, user_id: user_id, branch: @branch, seq: n.seq)
      end
      find(to_path)
    end
    alias rename move

    # --- content --------------------------------------------------------------

    def read(path, revision_id: nil)
      node = resolve(path)
      return nil unless node && node.ftype == 'file'
      return Content.at(node.record, revision_id) if revision_id
      e = node.entry
      return Content.head_cached(node.record, e.content_branch.name) if e.content_branch_id
      if (cb = node.record.branches.find_by(name: @branch.name))
        return Content.head_cached(node.record, cb.name)
      end
      return (node.binary? ? ''.b : '') unless e.revision_id
      Content.at(node.record, e.revision_id)
    end

    def ensure_content_branch!(node)
      e = node.entry
      return e.content_branch if e.content_branch_id
      raise "not a file: #{node.path}" unless e.ftype == 'file'
      bind_line!(node.record, at: e.revision_id)
    end

    # adopt! — an existing FileNode placed at `path` on this branch, with a
    # new content line at `revision_id` (or rebound if this branch already
    # has one).
    def adopt!(record, path, ftype:, revision_id: nil, user_id: nil)
      p = norm(path)
      ActiveRecord::Base.transaction do
        lock_tip!
        pending = []
        collect_missing_dirs!(File.dirname(p), pending, user_id)
        clash = head_lookup(p)
        raise "destination already exists: #{p}" if clash && clash.file_node_id != record.id
        cb = (ftype == 'file') ? bind_line!(record, at: revision_id, force_at: true) : nil
        n = if head_lookup_id(record.id)
              commit_path_op!(add: pending, rewrite: { record.id => { path: p, ftype: ftype, revision_id: nil } },
                              user_id: user_id)
            else
              pending << { file_node_id: record.id, path: p, ftype: ftype }
              commit_path_op!(add: pending, user_id: user_id)
            end
        Events.record!(project_id, :created, [{ file_node_id: record.id, path: p, ftype: ftype }],
                       user_id: user_id, branch: @branch, seq: n.seq)
        find(p)
      end
    end

    def text_heads(node_ids: nil)
      rows = ProjectDag.flatten(tip_node).select { |e| e.ftype == 'file' }
      rows = rows.select { |e| node_ids.include?(e.file_node_id) } if node_ids
      nodes = FileNode.where(id: rows.map(&:file_node_id), binary: false, symlink_target: nil).index_by(&:id)
      lines = ProjectDag.content_lines(nodes.keys, @branch)
      rows.filter_map do |e|
        next unless nodes[e.file_node_id]
        [e.file_node_id, e.path, lines[e.file_node_id]&.head_revision_id || e.revision_id]
      end
    end

    def content_of(node)
      e = node.entry
      if e.content_branch_id
        cb = e.content_branch
        return [cb.name, cb.head_revision_id]
      end
      [nil, e.revision_id]
    end

    def commit_path_op!(add: [], remove_ids: [], remove_paths: [], rewrite: {},
                        second_parent: nil, inherit: true, user_id: nil)
      node = ProjectDag.advance!(@branch, add: add, remove_ids: remove_ids, remove_paths: remove_paths,
                                 rewrite: rewrite, second_parent: second_parent, inherit: inherit, user_id: user_id)
      @index_hid = nil
      @branch.reload
      node
    end

    def ids_under(path)
      subtree(path).map(&:file_node_id)
    end

    def rewrites_for_move(from, to)
      e = head_lookup(from)
      e ? { e.file_node_id => { path: to } } : {}
    end

    def bind_line!(record, at: nil, force_at: false)
      cb = record.branches.find_by(name: @branch.name)
      if cb
        cb.update_columns(project_branch_id: @branch.id) unless cb.project_branch_id == @branch.id
        if at && (cb.head_revision_id.nil? || force_at)
          cb.update!(head_revision_id: at)
          cb.update_columns(origin_revision_id: at) if cb.origin_revision_id.nil? || force_at
        elsif at && cb.origin_revision_id.nil? && cb.head_revision_id == at
          cb.update_columns(origin_revision_id: at)
        end
        return cb
      end
      record.branches.create!(name: @branch.name, project_branch_id: @branch.id,
                              head_revision_id: at, origin_revision_id: at)
    end

    private

    def norm(path) = @store.send(:normalize, path)

    def tip_id
      ProjectBranch.where(id: @branch.id).pick(:head_node_id)
    end

    def tip_node
      hid = tip_id
      hid && ProjectNode.find_by(id: hid)
    end

    def current_head = tip_node

    def head_index
      hid = tip_id
      return ProjectDag::Index.empty unless hid
      if @index_hid != hid
        @index_hid = hid
        @index = ProjectDag::Index.new(ProjectNode.find(hid))
      end
      @index
    end

    def head_lookup(path)
      n = tip_node
      n && ProjectDag.lookup(n, path)
    end

    def head_lookup_id(id)
      n = tip_node
      n && ProjectDag.lookup_id(n, id)
    end

    def head_id_set
      ProjectDag.flatten(tip_node).map(&:file_node_id).to_set
    end

    def lock_tip!
      @branch.lock!
      @branch.reload
      @index_hid = nil
    end

    def root_node(create: true, user_id: nil)
      root = FileNode.find_by(project_id: project_id, path: '/')
      root ||= @store.send(:ensure_root!, user_id: user_id) if create
      return nil unless root
      Node.new(root, RootEntry.new(path: '/', ftype: 'folder', file_node: root, file_node_id: root.id), self)
    end

    def wrap(entry, deleted: false, source_node: nil)
      Node.new(entry.file_node, entry, self, deleted: deleted, source_node: source_node)
    end

    def listed_children(parent, include_tombstoned:)
      live = ProjectDag.children(tip_node, parent).map { |e| wrap(e) }
      return live unless include_tombstoned
      seen = live.map { |n| n.entry.file_node_id }.to_set
      extras = []
      node = tip_node&.parent
      while node
        ProjectDag.children(node, parent).each do |e|
          next if seen.include?(e.file_node_id)
          seen << e.file_node_id
          extras << wrap(e, deleted: true, source_node: node)
        end
        node = node.parent
      end
      (live + extras).sort_by { |n| n.path }
    end

    def subtree(path)
      ProjectDag.subtree(tip_node, path)
    end

    def index_for_tree(node, include_tombstoned:)
      if node.deleted? && node.source_node
        entries = ProjectDag.flatten(node.source_node)
        return [entries, entries.map(&:file_node_id).to_set]
      end
      live = ProjectDag.flatten(tip_node)
      return [live, Set.new] unless include_tombstoned
      live_ids = live.map(&:file_node_id).to_set
      extra = []
      n = tip_node&.parent
      while n
        ProjectDag.flatten(n).each do |e|
          next if live_ids.include?(e.file_node_id)
          live_ids << e.file_node_id
          extra << e
        end
        n = n.parent
      end
      [live + extra, extra.map(&:file_node_id).to_set]
    end

    def event_rows(entries)
      entries.map { |e| { file_node_id: e.file_node_id, path: e.path, ftype: e.ftype } }
    end

    def event_rows_from(pending)
      pending.map { |r| { file_node_id: r[:file_node_id], path: r[:path], ftype: r[:ftype] || 'file' } }
    end

    def live_path?(path, pending)
      pending.any? { |r| r[:path] == path } || !head_lookup(path).nil?
    end

    def ancestor_entry_by_path(p)
      live_ids = head_id_set
      node = tip_node
      while node
        e = ProjectDag.lookup(node, p)
        if e
          return nil if live_ids.include?(e.file_node_id)
          return { entry: e, node: node }
        end
        node = node.parent
      end
      nil
    end

    def ancestor_entry_by_id(id)
      node = tip_node
      while node
        e = ProjectDag.lookup_id(node, id)
        return { entry: e, node: node } if e
        node = node.parent
      end
      nil
    end

    def collect_missing_dirs!(path, pending, user_id, owner: nil, group: nil, mode: 0o755)
      p = norm(path)
      return if p == '/'
      return if pending.any? { |r| r[:path] == p }
      if (e = head_lookup(p))
        raise "not a directory: #{p}" unless e.ftype == 'folder'
        return
      end
      collect_missing_dirs!(File.dirname(p), pending, user_id)
      if (ghost = ancestor_entry_by_path(p))
        pending << { file_node_id: ghost[:entry].file_node_id, path: p, ftype: 'folder' }
      else
        record = mint_identity!(p, ftype: 'folder', owner: owner, group: group, mode: mode, user_id: user_id)
        pending << { file_node_id: record.id, path: p, ftype: 'folder' }
      end
    end

    def place_file!(path, pending, owner:, group:, mode:, user_id:, binary:, bind_content:, symlink_target: nil)
      ghost = ancestor_entry_by_path(path)
      if ghost && ghost[:entry].ftype == 'file'
        record = ghost[:entry].file_node
        record.update_columns(binary: binary, symlink_target: symlink_target, updated_at: Time.current)
        cb = bind_content ? bind_line!(record) : nil
        pending << { file_node_id: record.id, path: path, ftype: 'file', content_branch_id: cb&.id }
        return [record, cb]
      end
      record = mint_identity!(path, ftype: 'file', owner: owner, group: group, mode: mode,
                              user_id: user_id, binary: binary, symlink_target: symlink_target)
      cb = bind_content ? bind_line!(record) : nil
      pending << { file_node_id: record.id, path: path, ftype: 'file', content_branch_id: cb&.id }
      [record, cb]
    end

    def mint_identity!(path, ftype:, owner:, group:, mode:, user_id:, binary: false, symlink_target: nil)
      nid = SecureRandom.uuid
      FileNode.create!(
        id: nid,
        project_id: project_id,
        path: "#{IDENTITY_PREFIX}/#{nid}",
        cur_name: File.basename(path),
        ftype: ftype, binary: binary, symlink_target: symlink_target,
        owner: owner || @store.send(:default_owner), posix_group: group, posix_mode: mode,
        created_by: user_id, parent_id: nil
      )
    end
  end
end
