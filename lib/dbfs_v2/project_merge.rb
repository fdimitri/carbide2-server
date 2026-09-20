# frozen_string_literal: true
module DbfsV2
  # ProjectMerge — merge one project branch into its parent (or the reverse).
  #
  # A three-way merge of the whole tree keyed by node identity: base is the
  # child's fork/base node, ours the target's running head, theirs the
  # source's. For each node the side that changed wins; both changing
  # differently is a conflict the caller resolves:
  #
  #   rename/rename      A -> B here, A -> C there
  #   rename/delete      renamed here, deleted there (and the reverse)
  #   delete/modify      deleted here, content changed there (and the reverse)
  #   add/collision      added or renamed there onto a path a different
  #                      node holds here
  #   content            both changed the text and it does not auto-merge
  #
  # `resolutions` is { node_id => { action: 'ours' | 'theirs' | 'path',
  # path: } }. Content conflicts are resolved out of band with Store#merge.
  # Atomic: any unresolved conflict rolls everything back. `dry_run: true`
  # applies in a transaction that always rolls back.
  module ProjectMerge
    module_function

    Conflict = Struct.new(:node_id, :kind, :ours, :theirs, :detail, keyword_init: true) do
      def to_h = { id: node_id, kind: kind, ours: ours, theirs: theirs, detail: detail }.compact
    end

    # Returns
    #   { merged: true/false, dry_run:, source:, target:, base_seq:, seq:,
    #     actions: [{ id: node_id, kind: 'move'|'delete'|'add'|'content', ... }],
    #     conflicts: [{ id, kind, ours: {path, revision_id}, theirs: {...}, detail }] }
    def branches(store, source:, target: Branch::MAIN, resolutions: {}, user_id: nil, dry_run: false)
      src = pb!(store, source)
      tgt = pb!(store, target)
      raise ArgumentError, 'source and target are the same branch' if src.id == tgt.id
      child, parent =
        if src.forked_from_id == tgt.id then [src, tgt]
        elsif tgt.forked_from_id == src.id then [tgt, src]
        else raise ArgumentError, "#{src.name} and #{tgt.name} are not parent and child"
        end

      resolutions = (resolutions || {}).to_h { |k, v| [k.to_s, (v || {}).transform_keys(&:to_s)] }
      now  = store.seq
      base_seq    = child.base_seq || child.fork_seq
      base_branch = child.base_branch || parent
      base_node   = child.base_node || child.fork_node
      base = ProjectDag.view(base_branch, node: base_node)
      ours = ProjectDag.view(tgt)
      thrs = ProjectDag.view(src)

      plan, conflicts = plan(base.entries, ours.entries, thrs.entries, resolutions)
      result = { merged: false, dry_run: dry_run, source: src.name, target: tgt.name,
                 base: { branch: base_branch.name, seq: base_seq, node: base_node&.id }, seq: now,
                 actions: plan.map { |a| wire(a) }, conflicts: conflicts.map(&:to_h) }
      return result unless conflicts.empty?

      applied = []
      ActiveRecord::Base.transaction do
        apply!(store, tgt, src, plan, ours.entries, applied, conflicts, user_id)
        raise ActiveRecord::Rollback if dry_run || conflicts.any?
        # What was merged in is now in both: the source's running head is
        # the next merge base.
        cut = ProjectDag.freeze!(src)
        child.update_columns(base_seq: store.seq, base_branch_id: src.id,
                             base_node_id: cut&.id, updated_at: Time.current)
        ProjectMergeRecord.create!(project_id: store.project_id, source: src, target: tgt, seq: store.seq,
                                   base_seq: base_seq, user_id: user_id, created_at: Time.current)
      end
      [src, tgt, child].uniq.each(&:reload)
      result[:actions]   = applied.map { |a| wire(a) }
      result[:conflicts] = conflicts.map(&:to_h)
      result[:merged]    = conflicts.empty? && !dry_run
      result[:seq]       = store.seq
      result
    end

    # --- planning ---------------------------------------------------------

    # base/ours/theirs are { node_id => ProjectState::Entry }.
    def plan(base, ours, theirs, resolutions)
      actions, conflicts = [], []
      ids = (base.keys | ours.keys | theirs.keys)
      # Parents before children so a folder move/delete runs before anything
      # inside it (which the subtree op then already covered).
      ids.sort_by! { |id| (theirs[id] || ours[id] || base[id]).path }

      ids.each do |id|
        b, o, t = base[id], ours[id], theirs[id]
        t_ex = existence(b, t)
        o_ex = existence(b, o)
        t_ct = content_changed?(b, t)
        o_ct = content_changed?(b, o)
        next if t_ex == :same && !t_ct                         # theirs untouched
        res = resolutions[id.to_s]

        case t_ex
        when :added
          next if o                                            # already on ours (re-merge)
          add_at(actions, conflicts, ours, id, t, res, kind: 'add/collision')
          next
        when :deleted
          next if o.nil?                                       # gone on both
          if o_ex == :renamed || o_ct
            k = o_ex == :renamed ? 'rename/delete' : 'modify/delete'
            case res&.dig('action')
            when 'ours'   then next
            when 'theirs' then actions << { kind: 'delete', node: id, path: o.path }
            else conflicts << conflict(id, k, o, t, "#{o_ex == :renamed ? 'renamed' : 'modified'} on #{'ours'}, deleted on theirs")
            end
            next
          end
          actions << { kind: 'delete', node: id, path: o.path }
          next
        when :renamed
          if o.nil?
            case res&.dig('action')
            when 'ours'   then next
            when 'theirs', 'path'
              add_at(actions, conflicts, ours, id, t, res, kind: 'add/collision')
            else conflicts << conflict(id, 'delete/rename', o, t, 'deleted on ours, renamed on theirs')
            end
            next
          end
          if o_ex == :renamed && o.path != t.path
            case res&.dig('action')
            when 'ours'   then nil
            when 'theirs' then move_to(actions, conflicts, ours, id, o, t.path, 'rename/rename')
            when 'path'   then move_to(actions, conflicts, ours, id, o, res['path'], 'rename/rename')
            else conflicts << conflict(id, 'rename/rename', o, t, "#{b.path} renamed to #{o.path} on ours and #{t.path} on theirs")
            end
          elsif o_ex != :renamed
            move_to(actions, conflicts, ours, id, o, res&.dig('action') == 'path' ? res['path'] : t.path, 'rename/collision', res)
          end
        end

        # Content changed on theirs.
        next unless t_ct && t.ftype == 'file'
        if o.nil?
          # Deleted on ours, edited on theirs.
          case res&.dig('action')
          when 'ours'   then next
          when 'theirs', 'path' then add_at(actions, conflicts, ours, id, t, res, kind: 'add/collision')
          else conflicts << conflict(id, 'delete/modify', o, t, 'deleted on ours, modified on theirs')
          end
          next
        end
        next if o.revision_id == t.revision_id
        if o_ct
          next if res&.dig('action') == 'ours'
          actions << { kind: 'content', node: id, mode: 'merge', source_revision: t.revision_id, ours_revision: o.revision_id }
        else
          actions << { kind: 'content', node: id, mode: 'take', source_revision: t.revision_id, ours_revision: o.revision_id }
        end
      end
      [actions, conflicts]
    end

    def wire(a) = a.except(:node).merge(id: a[:node])

    def existence(b, x)
      return :same    if b.nil? && x.nil?
      return :added   if b.nil?
      return :deleted if x.nil?
      b.path == x.path ? :same : :renamed
    end

    def content_changed?(b, x)
      return false if b.nil? || x.nil? || x.ftype != 'file'
      b.revision_id != x.revision_id
    end

    def add_at(actions, conflicts, ours, id, t, res, kind:)
      path = res&.dig('action') == 'path' ? res['path'].to_s : t.path
      return if res&.dig('action') == 'ours'
      holder = ours.values.find { |e| e.path == path && e.file_node_id != id }
      if holder
        conflicts << conflict(id, kind, holder, t, "#{path} is #{holder.ftype} #{holder.file_node_id} on ours")
      else
        actions << { kind: 'add', node: id, path: path, ftype: t.ftype, revision: t.revision_id }
      end
    end

    def move_to(actions, conflicts, ours, id, o, to, kind, res = nil)
      return if to.nil? || to == o.path
      return if res&.dig('action') == 'ours'
      holder = ours.values.find { |e| e.path == to && e.file_node_id != id }
      if holder
        conflicts << conflict(id, kind, o, ProjectState::Entry.new(file_node_id: id, path: to, ftype: o.ftype),
                              "#{to} is #{holder.ftype} #{holder.file_node_id} on ours")
      else
        actions << { kind: 'move', node: id, from: o.path, to: to }
      end
    end

    def conflict(id, kind, o, t, detail)
      Conflict.new(node_id: id, kind: kind, detail: detail,
                   ours:   o && { path: o.path, revision_id: o.revision_id },
                   theirs: t && { path: t.path, revision_id: t.revision_id })
    end

    # --- applying ---------------------------------------------------------

    ORDER = { 'delete' => 0, 'move' => 1, 'add' => 2, 'content' => 3 }.freeze

    # `paths` follows the target's tree through the identity ops so content
    # ops find each node where it is now.
    def apply!(store, tgt, src, plan, ours, applied, conflicts, user_id)
      b = tgt.name
      fs = store.branch_fs(tgt)
      paths = ours.transform_values(&:path)
      remove_ids = []
      rewrite = {}
      add = []

      plan.sort_by { |a| ORDER[a[:kind]] }.each do |a|
        case a[:kind]
        when 'delete'
          node = store.find(a[:path], branch: b)
          next unless node && node.id == a[:node]
          fs.ids_under(a[:path]).each { |id| remove_ids << id }
          paths.reject! { |_, p| p == a[:path] || p.start_with?("#{a[:path]}/") }
          applied << a
        when 'move'
          cur = store.find(a[:to], branch: b)
          next if cur && cur.id == a[:node]
          from = paths[a[:node]]
          next unless from && store.find(from, branch: b)&.id == a[:node]
          fs.rewrites_for_move(from, a[:to]).each { |id, attrs| rewrite[id] = attrs }
          paths.each { |id, p| paths[id] = "#{a[:to]}#{p.delete_prefix(from)}" if p == from || p.start_with?("#{from}/") }
          applied << a.merge(from: from)
        when 'add'
          record = FileNode.find(a[:node])
          cb = (a[:ftype] == 'file') ? fs.bind_line!(record, at: a[:revision], force_at: true) : nil
          add << { file_node_id: record.id, path: a[:path], ftype: a[:ftype], content_branch_id: cb&.id }
          fs.send(:collect_missing_dirs!, File.dirname(a[:path]), add, user_id)
          paths[a[:node]] = a[:path]
          applied << a
        end
      end

      fs.commit_path_op!(add: add, remove_ids: remove_ids, rewrite: rewrite,
                         second_parent: src.head_node, user_id: user_id)

      plan.each do |a|
        next unless a[:kind] == 'content'
        path = paths[a[:node]] or raise "node #{a[:node]} is not on #{b}"
        node, tname = store.locate(path, b, for_write: true)
        record = node.resolve || node
        if a[:mode] == 'take'
          row = record.branches.find_by!(name: tname)
          row.update!(head_revision_id: a[:source_revision]) unless row.head_revision_id == a[:source_revision]
          DocumentCache.invalidate(record.id, tname)
          applied << a.merge(head: a[:source_revision])
        else
          sname = source_row_name(record, a[:source_revision])
          unless sname
            conflicts << Conflict.new(node_id: a[:node], kind: 'content', detail: 'source revision has no branch row',
                                      ours: { path: node.path, revision_id: a[:ours_revision] },
                                      theirs: { path: node.path, revision_id: a[:source_revision] })
            next
          end
          res = store.merge(node.path, target: tname, source: sname, auto: true, user_id: user_id, branch: b)
          if res[:merged]
            applied << a.merge(head: res[:head], fast_forward: res[:fast_forward] == true, source_branch: sname)
          elsif res[:reason] == 'already at source head'
            next
          else
            conflicts << Conflict.new(node_id: a[:node], kind: 'content', detail: res[:reason],
                                      ours: { path: node.path, revision_id: a[:ours_revision], branch: tname },
                                      theirs: { path: node.path, revision_id: a[:source_revision], branch: sname })
          end
        end
      end
    end

    # The per-file branch row whose head is `rev` (the source's content row).
    def source_row_name(record, rev)
      (record.branches.find_by(head_revision_id: rev) || record.all_branches.find_by(head_revision_id: rev))&.name
    end

    def pb!(store, name)
      store.project_branch(name.to_s) or raise ArgumentError, "no project branch #{name}"
    end
  end
end
