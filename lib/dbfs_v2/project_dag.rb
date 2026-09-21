# frozen_string_literal: true
require 'digest'
require 'set'

module DbfsV2
  # ProjectDag — stored project-level DAG. A node is kind/parents/name plus
  # a merkle directory root. Running nodes point at a live content line
  # (submodule→branch). Snapshots freeze identity-revs on the file entries
  # and hang off the running head; HEAD does not move onto a snapshot.
  #
  # A path op copies only the dirty spine (changed leaf + ancestor dirs).
  # Unchanged sibling directories keep their tree id. Content lines are not
  # stored on tree entries, so a fork shares the parent's running trees.
  # Running nodes include project_branch_id in the hash; trees do not.
  module ProjectDag
    module_function

    FLATTEN_SQL = <<~SQL.freeze
      WITH RECURSIVE walk AS (
        SELECT e.name, e.file_node_id, e.ftype, e.child_tree_id, e.revision_id,
               ('/' || e.name) AS path
        FROM project_tree_entries e
        WHERE e.tree_id = ?
        UNION ALL
        SELECT c.name, c.file_node_id, c.ftype, c.child_tree_id, c.revision_id,
               (w.path || '/' || c.name) AS path
        FROM project_tree_entries c
        INNER JOIN walk w ON c.tree_id = w.child_tree_id
      )
      SELECT path, file_node_id, ftype, child_tree_id, revision_id
      FROM walk
      ORDER BY path
    SQL

    CHAIN_SQL = <<~SQL.freeze
      WITH RECURSIVE chain AS (
        SELECT id, parent_id, second_parent_id, project_branch_id, seq, kind, name
        FROM project_nodes
        WHERE id = ?
        UNION ALL
        SELECT n.id, n.parent_id, n.second_parent_id, n.project_branch_id, n.seq, n.kind, n.name
        FROM project_nodes n
        INNER JOIN chain c ON n.id = c.parent_id
      )
      SELECT id, parent_id, second_parent_id, project_branch_id, seq, kind, name
      FROM chain
    SQL

    REVISIONS_AT_SQL = <<~SQL.freeze
      SELECT DISTINCT ON (branch_id) branch_id, revision_id
      FROM branch_heads
      WHERE branch_id IN (?) AND seq <= ?
      ORDER BY branch_id, seq DESC
    SQL

    def advance!(branch, add: [], remove_ids: [], remove_paths: [], rewrite: {},
                 second_parent: nil, parent: nil, inherit: true, user_id: nil, seq: nil)
      parent ||= branch.head_node
      builder = Builder.new((inherit && parent) ? parent.root_tree_id : nil)
      by_id = nil
      if (Array(remove_ids).any? || rewrite.any?) && parent
        by_id = flatten(parent).index_by(&:file_node_id)
      end
      Array(remove_paths).sort_by { |p| -p.length }.each { |p| builder.remove(p) }
      Array(remove_ids).filter_map { |id| by_id&.[](id)&.path }
                       .sort_by { |p| -p.length }
                       .each { |p| builder.remove(p) }

      rewrite.each do |id, attrs|
        e = by_id&.[](id)
        next unless e
        h = attrs.transform_keys(&:to_sym)
        new_path = (h[:path] || e.path).to_s
        ftype = (h[:ftype] || e.ftype).to_s
        rev = h.key?(:revision_id) ? h[:revision_id] : e.revision_id
        builder.relocate(e.path, new_path, file_node_id: id, ftype: ftype, revision_id: rev)
      end

      Array(add).each do |r|
        h = r.transform_keys(&:to_sym)
        builder.add(h[:path], file_node_id: h[:file_node_id], ftype: h[:ftype] || 'file',
                    revision_id: h[:revision_id], child_tree_id: h[:child_tree_id])
      end

      new_root = builder.commit!
      if second_parent.nil? && parent && new_root == parent.root_tree_id
        return parent
      end
      insert!(branch, parent: parent, second_parent: second_parent, kind: ProjectNode::RUNNING,
              root_tree_id: new_root, user_id: user_id, seq: seq)
    end

    def snapshot!(branch, name: nil, user_id: nil, seq: nil)
      ActiveRecord::Base.transaction do
        branch.lock!
        branch.reload
        head = branch.head_node
        raise ArgumentError, 'nothing to snapshot' unless head
        if name && ProjectNode.snapshots.where(project_id: branch.project_id, name: name).exists?
          dummy = ProjectNode.new(project_id: branch.project_id, kind: ProjectNode::SNAPSHOT, name: name)
          dummy.errors.add(:name, :taken)
          raise ActiveRecord::RecordInvalid, dummy
        end
        root = freeze_tree(head.root_tree_id, branch)
        insert!(branch, parent: head, kind: ProjectNode::SNAPSHOT, name: name,
                root_tree_id: root, user_id: user_id, seq: seq)
      end
    end

    # Unnamed snapshot of the running head. Used as a fork/merge-base cut so
    # later writes on those content lines cannot move the recorded tree.
    def freeze!(branch, user_id: nil, seq: nil)
      return nil unless branch.head_node
      snapshot!(branch, name: nil, user_id: user_id, seq: seq)
    end

    def insert!(branch, parent:, root_tree_id:, kind:, second_parent: nil, name: nil, user_id: nil, seq: nil)
      root_tree_id ||= put_tree!([])
      id = node_hash(parent_id: parent&.id, second_parent_id: second_parent&.id,
                     kind: kind, name: name, root_tree_id: root_tree_id,
                     project_branch_id: branch.id)
      now = Time.now.utc
      node = nil
      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          seq ||= Clock.tick!(branch.project_id)
          node = ProjectNode.create!(
            id: id, project_id: branch.project_id, project_branch_id: branch.id,
            parent_id: parent&.id, second_parent_id: second_parent&.id,
            root_tree_id: root_tree_id, seq: seq,
            kind: kind, name: name, user_id: user_id, created_at: now, updated_at: now
          )
        end
      rescue ActiveRecord::RecordNotUnique
        node = ProjectNode.find_by(id: id)
        raise unless node
      end
      point_head!(branch, node) if kind == ProjectNode::RUNNING
      node
    end

    def node_hash(parent_id:, second_parent_id:, kind:, name:, root_tree_id:, project_branch_id:)
      Digest::SHA256.hexdigest(
        "#{kind}\0#{parent_id}\0#{second_parent_id}\0#{name}\0#{root_tree_id}\0#{project_branch_id}"
      )
    end

    def hash_tree(entries)
      buf = +"tree\n"
      entries.sort_by { |e| e[:name].to_s }.each do |e|
        buf << "#{e[:name]}\t#{e[:file_node_id]}\t#{e[:ftype] || 'file'}\t#{e[:child_tree_id]}\t#{e[:revision_id]}\n"
      end
      Digest::SHA256.hexdigest(buf)
    end

    def put_tree!(entries)
      kids = entries.sort_by { |e| e[:name].to_s }
      id = hash_tree(kids)
      return id if ProjectTree.exists?(id: id)
      now = Time.now.utc
      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          ProjectTree.create!(id: id, created_at: now, updated_at: now)
          if kids.any?
            ProjectTreeEntry.insert_all!(kids.map { |e|
              { tree_id: id, name: e[:name], file_node_id: e[:file_node_id],
                ftype: e[:ftype] || 'file', child_tree_id: e[:child_tree_id],
                revision_id: e[:revision_id], created_at: now, updated_at: now }
            })
          end
        end
      rescue ActiveRecord::RecordNotUnique
        # another writer inserted the same tree
      end
      id
    end

    # HEAD of `branch` (or a specific node) as a ProjectState view: paths and
    # the live (or frozen) identity-rev of each file. `seq:` is a clock cut:
    # the running node with seq ≤ S, content from each line's reflog at S.
    def view(branch, node: nil, seq: nil)
      n = node
      if n.nil? && !seq.nil?
        n = node_at(branch, seq)
      elsif n.nil?
        hid = ProjectBranch.where(id: branch.id).pick(:head_node_id)
        n = hid && ProjectNode.find_by(id: hid)
      end
      entries = {}
      if n
        rows = flatten(n)
        lines = content_lines(rows.map(&:file_node_id), n.snapshot? ? n.project_branch : branch)
        revs = (!n.snapshot? && seq) ? revisions_at(lines.values.map(&:id), seq) : nil
        rows.each do |e|
          cb = lines[e.file_node_id]
          rev = if n.snapshot?
                  e.revision_id
                elsif revs
                  (cb && revs[cb.id.to_s]) || origin_rev_at(cb, seq) || e.revision_id
                else
                  cb&.head_revision_id || e.revision_id
                end
          entries[e.file_node_id] = ProjectState::Entry.new(
            file_node_id: e.file_node_id, path: e.path, ftype: e.ftype,
            branch: cb&.name, revision_id: rev
          )
        end
      end
      ProjectState.new(project_id: branch.project_id, entries: entries)
    end

    # Latest running node on `branch` whose seq is ≤ `seq`. Walks HEAD's
    # parent chain. Stops before walking into the parent branch when this
    # branch was born after `seq`. Running nodes include `project_branch_id`
    # in the hash, so two branches never share a node row.
    def node_at(branch, seq)
      seq = seq.to_i
      born = branch.seq.to_i
      return nil if !branch.main? && seq < born
      hid = ProjectBranch.where(id: branch.id).pick(:head_node_id)
      n = hid && ProjectNode.find_by(id: hid)
      while n
        return n if n.running? && n.seq.to_i <= seq
        parent = n.parent
        break if parent && n.project_branch_id == branch.id && parent.project_branch_id != branch.id && n.seq.to_i > seq
        n = parent
      end
      nil
    end

    def revision_at(content_branch, seq)
      return nil unless content_branch
      revisions_at([content_branch.id], seq)[content_branch.id.to_s] || origin_rev_at(content_branch, seq)
    end

    def origin_rev_at(content_branch, seq)
      return nil unless content_branch&.origin_revision_id
      rseq = Revision.where(id: content_branch.origin_revision_id).pick(:seq)
      rseq.to_i.positive? && rseq.to_i <= seq.to_i ? content_branch.origin_revision_id : nil
    end

    # One query: each content line's identity-rev at clock `seq`.
    def revisions_at(branch_ids, seq)
      ids = Array(branch_ids).compact.uniq
      return {} if ids.empty?
      sql = ActiveRecord::Base.sanitize_sql_array([REVISIONS_AT_SQL, ids, seq.to_i])
      ActiveRecord::Base.connection.select_all(sql).each_with_object({}) do |r, h|
        h[r['branch_id'].to_s] = r['revision_id']
      end
    end

    # First-parent chain from HEAD to genesis, oldest first. One recursive query.
    def first_parent_chain(branch)
      hid = branch.head_node_id || ProjectBranch.where(id: branch.id).pick(:head_node_id)
      return [] unless hid
      sql = ActiveRecord::Base.sanitize_sql_array([CHAIN_SQL, hid])
      ActiveRecord::Base.connection.select_all(sql).to_a.reverse
    end

    def lookup(node, path)
      return nil unless node&.root_tree_id
      parts = split_path(path)
      return nil if parts.empty?
      tree_id = node.root_tree_id
      entry = nil
      parts.each do |name|
        return nil unless tree_id
        entry = ProjectTreeEntry.find_by(tree_id: tree_id, name: name)
        return nil unless entry
        tree_id = entry.child_tree_id
      end
      hydrate(entry, path_join(parts), node)
    end

    def lookup_id(node, id)
      flatten(node).find { |e| e.file_node_id == id }
    end

    def flatten(node)
      return [] unless node&.root_tree_id
      hydrate_rows(flatten_raw(node.root_tree_id), node)
    end

    def children(node, path)
      return [] unless node
      if path == '/'
        tree_id = node.root_tree_id
        prefix = ''
      else
        e = lookup(node, path)
        return [] unless e && e.ftype == 'folder'
        tree_id = e.child_tree_id
        prefix = path
      end
      return [] unless tree_id
      ProjectTreeEntry.where(tree_id: tree_id).order(:name).map do |te|
        hydrate(te, "#{prefix}/#{te.name}", node)
      end
    end

    def subtree(node, path)
      flatten(node).select { |e| e.path == path || e.path.start_with?("#{path}/") }
    end

    def content_line(file_node_id, project_branch)
      return nil unless file_node_id && project_branch
      Branch.unscoped.find_by(file_node_id: file_node_id, project_branch_id: project_branch.id)
    end

    def content_lines(file_node_ids, project_branch)
      ids = Array(file_node_ids).uniq
      return {} if ids.empty? || project_branch.nil?
      Branch.unscoped.where(file_node_id: ids, project_branch_id: project_branch.id)
            .index_by(&:file_node_id)
    end

    def point_head!(branch, node)
      now = Time.now.utc
      branch.update_columns(head_node_id: node.id, updated_at: now)
      if branch.association(:head_node).loaded?
        branch.association(:head_node).reset
      end
      branch.head_node_id = node.id
    end

    def flatten_raw(root_tree_id)
      return [] unless root_tree_id
      sql = ActiveRecord::Base.sanitize_sql_array([FLATTEN_SQL, root_tree_id])
      ActiveRecord::Base.connection.select_all(sql).map do |r|
        { path: r['path'], file_node_id: r['file_node_id'], ftype: r['ftype'],
          child_tree_id: r['child_tree_id'], revision_id: r['revision_id'] }
      end
    end

    # Stamp each file's live head onto directory objects. Running entries
    # have revision_id nil, so the first freeze cannot reuse those trees —
    # every directory hashes differently. After that, put_tree! reuses any
    # directory whose stamped children already exist. The walk is O(files);
    # extra storage is only dirs that actually changed.
    def freeze_tree(root_tree_id, project_branch)
      rows = flatten_raw(root_tree_id)
      lines = content_lines(rows.filter_map { |r| r[:file_node_id] if r[:ftype] == 'file' }, project_branch)
      builder = Builder.new(nil)
      rows.each do |r|
        rev = r[:ftype] == 'file' ? (r[:revision_id] || lines[r[:file_node_id]]&.head_revision_id) : nil
        builder.add(r[:path], file_node_id: r[:file_node_id], ftype: r[:ftype], revision_id: rev)
      end
      builder.commit!
    end

    def hydrate(te, path, node)
      pb = node.project_branch
      cb = te.ftype == 'file' ? content_line(te.file_node_id, pb) : nil
      Index::Entry.new(
        path: path, file_node_id: te.file_node_id, ftype: te.ftype,
        revision_id: te.revision_id, child_tree_id: te.child_tree_id,
        content_branch_id: cb&.id, project_branch: pb, file_node: te.file_node
      )
    end

    def hydrate_rows(raw, node)
      return [] if raw.empty?
      fns = FileNode.where(id: raw.map { |r| r[:file_node_id] }).index_by(&:id)
      pb = node.project_branch
      lines = content_lines(raw.filter_map { |r| r[:file_node_id] if r[:ftype] == 'file' }, pb)
      raw.map do |r|
        cb = lines[r[:file_node_id]]
        Index::Entry.new(
          path: r[:path], file_node_id: r[:file_node_id], ftype: r[:ftype],
          revision_id: r[:revision_id], child_tree_id: r[:child_tree_id],
          content_branch_id: cb&.id, project_branch: pb, file_node: fns[r[:file_node_id]]
        )
      end
    end

    def split_path(path)
      path.to_s.delete_prefix('/').split('/').reject(&:empty?)
    end

    def path_join(parts)
      "/#{parts.join('/')}"
    end

    # In-memory copy-on-write over merkle directories. Only dirs that gain
    # or lose a child are rewritten; sibling tree ids are kept.
    class Builder
      def initialize(root_tree_id)
        @root_id = root_tree_id
        @dirs = {}
        @dirty = Set.new
      end

      def add(path, file_node_id:, ftype:, revision_id: nil, child_tree_id: nil)
        path = path.to_s
        return if path.empty? || path == '/'
        parent = parent_of(path)
        name = File.basename(path)
        entries = dir_entries(parent)
        if ftype.to_s == 'folder' && (child_tree_id.nil? || child_tree_id == :pending)
          @dirs[path] ||= {}
          mark_dirty(path)
          child_tree_id = :pending
        end
        entries[name] = { name: name, file_node_id: file_node_id, ftype: ftype.to_s,
                          child_tree_id: child_tree_id, revision_id: revision_id }
        mark_dirty(parent)
      end

      def remove(path)
        path = path.to_s
        return if path.empty? || path == '/'
        parent = parent_of(path)
        name = File.basename(path)
        entries = dir_entries(parent)
        entries.delete(name)
        drop_dir_state(path)
        mark_dirty(parent)
      end

      def relocate(old_path, new_path, file_node_id:, ftype:, revision_id: nil)
        old_path = old_path.to_s
        new_path = new_path.to_s
        if old_path == new_path
          entries = dir_entries(parent_of(old_path))
          if (e = entries[File.basename(old_path)])
            e[:ftype] = ftype.to_s
            e[:revision_id] = revision_id
            e[:file_node_id] = file_node_id
            mark_dirty(parent_of(old_path))
          end
          return
        end
        old_ent = dir_entries(parent_of(old_path))[File.basename(old_path)]
        child_id = (ftype.to_s == 'folder') ? old_ent&.[](:child_tree_id) : nil
        stash = take_dir_state(old_path)
        remove(old_path)
        add(new_path, file_node_id: file_node_id, ftype: ftype, revision_id: revision_id,
            child_tree_id: (child_id == :pending) ? nil : child_id)
        stash.each do |p, ents|
          @dirs[new_path + p.delete_prefix(old_path)] = ents
        end
      end

      def commit!
        return @root_id unless @dirty.include?('/')
        write_dir('/')
      end

      private

      def parent_of(path)
        p = File.dirname(path)
        (p == '.' || p.empty?) ? '/' : p
      end

      def join(dir, name)
        dir == '/' ? "/#{name}" : "#{dir}/#{name}"
      end

      def mark_dirty(path)
        p = path
        loop do
          @dirty << p
          break if p == '/'
          p = parent_of(p)
        end
      end

      def dir_entries(path)
        @dirs[path] ||= begin
          tid = tree_id_for(path)
          load_entries(tid)
        end
      end

      def tree_id_for(path)
        return @root_id if path == '/'
        parent = dir_entries(parent_of(path))
        parent[File.basename(path)]&.[](:child_tree_id)
      end

      def load_entries(tree_id)
        return {} if tree_id.nil? || tree_id == :pending
        ProjectTreeEntry.where(tree_id: tree_id).order(:name).each_with_object({}) do |e, h|
          h[e.name] = { name: e.name, file_node_id: e.file_node_id, ftype: e.ftype,
                        child_tree_id: e.child_tree_id, revision_id: e.revision_id }
        end
      end

      def drop_dir_state(path)
        @dirs.delete(path)
        prefix = "#{path}/"
        @dirs.keys.each { |p| @dirs.delete(p) if p.start_with?(prefix) }
      end

      def take_dir_state(path)
        stash = {}
        prefix = "#{path}/"
        @dirs.keys.each do |p|
          next unless p == path || p.start_with?(prefix)
          new_key = p == path ? path : p
          stash[new_key] = @dirs.delete(p)
        end
        # keys rewritten by caller after it knows new_path
        stash.transform_keys { |p| p }
      end

      def write_dir(path)
        entries = dir_entries(path)
        entries.each_value do |e|
          next unless e[:ftype] == 'folder'
          child = join(path, e[:name])
          if @dirty.include?(child) || e[:child_tree_id].nil? || e[:child_tree_id] == :pending
            e[:child_tree_id] = write_dir(child)
          end
        end
        ProjectDag.put_tree!(entries.values)
      end
    end

    # Flat-path facade over a merkle node so `head_entries.find_by(path:)`
    # and the existing tests keep working. Content lines are resolved via
    # (file_node, project_branch), not stored on the tree.
    class Index
      include Enumerable

      class Entry
        attr_accessor :path, :file_node_id, :ftype, :revision_id, :child_tree_id,
                      :content_branch_id, :project_branch, :file_node

        def initialize(path:, file_node_id:, ftype:, revision_id: nil, child_tree_id: nil,
                       content_branch_id: nil, project_branch: nil, file_node: nil)
          @path = path
          @file_node_id = file_node_id
          @ftype = ftype
          @revision_id = revision_id
          @child_tree_id = child_tree_id
          @content_branch_id = content_branch_id
          @project_branch = project_branch
          @file_node = file_node
        end

        def folder?  = ftype == 'folder'
        def root?    = path == '/'
        def deleted? = false

        def content_branch
          return @content_branch if defined?(@content_branch)
          @content_branch = content_branch_id && Branch.unscoped.find_by(id: content_branch_id)
        end

        def reload
          if project_branch && file_node_id
            cb = ProjectDag.content_line(file_node_id, project_branch)
            @content_branch_id = cb&.id
            @content_branch = cb
          end
          self
        end
      end

      def self.empty
        new(nil)
      end

      def initialize(node)
        @node = node
      end

      def each
        return enum_for(:each) unless block_given?
        rows.each { |r| yield r }
      end

      def find_by(path: nil, file_node_id: nil)
        if path && file_node_id.nil?
          return ProjectDag.lookup(@node, path)
        end
        if file_node_id && path.nil?
          return ProjectDag.lookup_id(@node, file_node_id)
        end
        rows.find { |e|
          (path.nil? || e.path == path) && (file_node_id.nil? || e.file_node_id == file_node_id)
        }
      end

      def find_by!(**kw)
        find_by(**kw) or raise ActiveRecord::RecordNotFound, "no project entry #{kw.inspect}"
      end

      def exists?(path: nil, file_node_id: nil)
        if path.nil? && file_node_id.nil?
          return false unless @node&.root_tree_id
          return ProjectTreeEntry.where(tree_id: @node.root_tree_id).exists?
        end
        !find_by(path: path, file_node_id: file_node_id).nil?
      end

      def where(**attrs)
        Slice.new(rows.select { |e| attrs.all? { |k, v| e.public_send(k) == v } })
      end

      def order(*)
        self
      end

      def includes(*)
        self
      end

      def pluck(*cols)
        rows.map { |e|
          vals = cols.map { |c| e.public_send(c) }
          cols.size == 1 ? vals[0] : vals
        }
      end

      def to_a
        rows
      end

      def select(&block)
        block ? rows.select(&block) : self
      end

      def none?
        !exists?
      end

      class Slice
        include Enumerable

        def initialize(rows)
          @rows = rows
        end

        def each(&block) = @rows.each(&block)
        def exists? = @rows.any?
        def to_a = @rows
        def order(*) = self
      end

      private

      def rows
        @rows ||= ProjectDag.flatten(@node)
      end
    end
  end
end
