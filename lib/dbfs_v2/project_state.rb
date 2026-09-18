# frozen_string_literal: true
module DbfsV2
  # ProjectState — the project at (S, B) (ADR-042).
  #
  # Derived, never stored unless named (Store#snapshot!). Per file:
  #   existence / path  = fold of the node's FileEvents with seq <= S
  #                       (created/restored => present, deleted => absent,
  #                        renamed => path only)
  #   branch            = branch_set.resolve(file) among branches live at S
  #   revision          = the branch's newest reflog entry with seq <= S
  # Folders carry existence only. The root is implicit.
  class ProjectState
    Entry = Struct.new(:file_node_id, :path, :ftype, :branch, :revision_id, keyword_init: true) do
      def folder? = ftype == 'folder'
      def to_h    = { id: file_node_id, path: path, ftype: ftype, branch: branch, revision_id: revision_id }
    end

    attr_reader :project_id, :seq, :branch_set, :entries

    def self.at(store, seq:, branch_set: Branch::MAIN)
      bset = BranchSet.wrap(branch_set)
      pid  = store.project_id
      s    = Integer(seq)

      present = fold_events(pid, s)
      file_ids = present.select { |_, e| e[:ftype] == 'file' }.keys
      chosen   = resolve_branches(file_ids, bset, s)          # file_id => Branch or nil
      heads    = heads_at(chosen.values.compact.map(&:id), s) # branch_id => revision_id

      entries = present.to_h do |id, e|
        b = chosen[id]
        [id, Entry.new(file_node_id: id, path: e[:path], ftype: e[:ftype],
                       branch: b&.name, revision_id: b && heads[b.id])]
      end
      new(project_id: pid, seq: s, branch_set: bset, entries: entries)
    end

    # Rehydrate a materialized manifest (ProjectSnapshot#manifest).
    def self.from_h(h)
      h = h.transform_keys(&:to_s)
      entries = Array(h['entries']).to_h do |e|
        e = e.transform_keys(&:to_s)
        [e['id'], Entry.new(file_node_id: e['id'], path: e['path'], ftype: e['ftype'],
                            branch: e['branch'], revision_id: e['revision_id'])]
      end
      new(project_id: h['project_id'], seq: h['seq'],
          branch_set: h['branch_set'] && BranchSet.wrap(h['branch_set']), entries: entries)
    end

    # The merge base of two states: per file present in both, the lowest
    # common ancestor of its two revisions over the full DAG (ADR-036). Files
    # on one side only are absent (they are adds relative to the base). Like
    # git's recursive merge base, this state need never have existed; it is
    # an input to per-file merges, not something to check out.
    def self.merge_base(a, b)
      entries = {}
      (a.entries.keys & b.entries.keys).each do |id|
        ea, eb = a.entries[id], b.entries[id]
        base =
          if ea.revision_id && eb.revision_id
            Merge.lowest_common_ancestor(FileNode.find(id), ea.revision_id, eb.revision_id)
          end
        entries[id] = Entry.new(file_node_id: id, path: ea.path, ftype: ea.ftype, branch: nil, revision_id: base)
      end
      new(project_id: a.project_id, seq: [a.seq, b.seq].min, branch_set: nil, entries: entries)
    end

    def initialize(project_id:, seq:, branch_set:, entries:)
      @project_id = project_id
      @seq        = seq
      @branch_set = branch_set
      @entries    = entries.freeze
    end

    def [](path)  = @entries.values.find { |e| e.path == path }
    def paths     = @entries.values.map(&:path).sort
    def files     = @entries.values.reject(&:folder?)
    def size      = @entries.size
    def include?(path) = !self[path].nil?

    # Content of a file in this state, by replay at its pinned revision.
    def read(path)
      e = self[path]
      raise "no such file in state: #{path}" unless e
      return nil if e.folder?
      return '' unless e.revision_id
      Content.at(FileNode.find(e.file_node_id), e.revision_id)
    end

    # Change set from self to `other`, keyed by node identity, so a rename is
    # a rename and not a delete plus an add.
    def diff(other)
      out = { added: [], removed: [], renamed: [], modified: [] }
      other.entries.each do |id, e|
        mine = @entries[id]
        if mine.nil?
          out[:added] << e
        else
          out[:renamed]  << { from: mine.path, to: e.path, entry: e } if mine.path != e.path
          out[:modified] << { from: mine.revision_id, to: e.revision_id, entry: e } if mine.revision_id != e.revision_id
        end
      end
      @entries.each { |id, e| out[:removed] << e unless other.entries.key?(id) }
      out
    end

    # Is `other` behind or equal to self? Every file in `other` is here with
    # the same revision or an ancestor of ours, or it is gone here because it
    # was deleted after `other`'s cut. Content ancestry is per-file (ADR-036).
    def contains?(other)
      other.entries.all? do |id, e|
        mine = @entries[id]
        if mine
          e.revision_id.nil? || mine.revision_id == e.revision_id ||
            (mine.revision_id && Merge.ancestors(FileNode.find(id), mine.revision_id).include?(e.revision_id))
        else
          FileEvent.where(file_node_id: id, kind: 'deleted').where('seq > ?', other.seq).exists?
        end
      end
    end

    def to_h
      { project_id: @project_id, seq: @seq, branch_set: @branch_set&.to_h,
        entries: @entries.values.sort_by(&:path).map(&:to_h) }
    end

    class << self
      private

      # { file_node_id => { path:, ftype: } } for nodes present at S.
      def fold_events(project_id, s)
        present = {}
        FileEvent.where(project_id: project_id, seq: ..s).order(:seq, :id)
                 .pluck(:file_node_id, :kind, :path, :ftype).each do |id, kind, path, ftype|
          case kind
          when 'created', 'restored' then present[id] = { path: path, ftype: ftype }
          when 'deleted'             then present.delete(id)
          when 'renamed'             then present[id][:path] = path if present.key?(id)
          end
        end
        present
      end

      # The branch each file resolves to under `bset` at S: the first candidate
      # name that names a branch live at S, else the file's main. Deleted
      # branches with a later deletion still resolve for earlier cuts.
      def resolve_branches(file_ids, bset, s)
        return {} if file_ids.empty?
        by_file = Branch.where(file_node_id: file_ids).group_by(&:file_node_id)
        file_ids.to_h do |id|
          rows = (by_file[id] || []).select { |b| b.live_at?(s) }
          pick = bset.candidates(id).lazy.filter_map { |n| rows.find { |b| b.name == n } }.first
          [id, pick || rows.find { |b| b.name == Branch::MAIN }]
        end
      end

      # branch_id => head revision at S, from the reflog (one indexed scan).
      def heads_at(branch_ids, s)
        return {} if branch_ids.empty?
        BranchHead.where(branch_id: branch_ids, seq: ..s)
                  .select('DISTINCT ON (branch_id) branch_id, revision_id')
                  .order('branch_id, seq DESC, id DESC')
                  .map { |r| [r.branch_id, r.revision_id] }.to_h
      end
    end
  end
end
