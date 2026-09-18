# frozen_string_literal: true
module DbfsV2
  # Graph — serialize a file's revision DAG into a neutral structure (nodes,
  # edges, branch heads) that a client can render or traverse, plus a DOT
  # export for quick visualisation. This is a read-only projection; it never
  # mutates the log.
  module Graph
    module_function

    # Returns:
    #   {
    #     path:     '/f.rb',
    #     branches: { 'main' => head_id, 'feature' => head_id },
    #     nodes:    [ { id:, parent:, second_parent:, change_type:, branch:, user_id:, timestamp: }, ... ],
    #     edges:    [ { from:, to:, kind: 'parent' | 'second_parent' }, ... ],
    #     heads:    [ { branch:, revision: } ]   # all branch tips
    #   }
    # Nodes/edges are ordered topologically (parent before child) so a consumer
    # can render bottom-up without extra work.
    def dump(store, path)
      node = store.find(path)
      raise "no such file: #{path}" unless node

      revs = node.revisions.order(:timestamp, :id).to_a
      by_id = revs.index_by(&:id)

      nodes = revs.map do |r|
        {
          id: r.id,
          parent: r.parent_id,
          second_parent: r.second_parent_id,
          change_type: r.change_type,
          branch: r.branch_id,
          user_id: r.user_id,
          timestamp: r.timestamp&.iso8601
        }
      end

      edges = revs.flat_map do |r|
        out = []
        out << { from: r.parent_id, to: r.id, kind: 'parent' } if r.parent_id && by_id.key?(r.parent_id)
        out << { from: r.second_parent_id, to: r.id, kind: 'second_parent' } if r.second_parent_id && by_id.key?(r.second_parent_id)
        out
      end

      branches = {}
      heads = node.branches.order(:name).map do |b|
        branches[b.name] = b.head_revision_id
        { branch: b.name, revision: b.head_revision_id }
      end

      {
        path: node.path,
        branches: branches,
        nodes: nodes,
        edges: edges,
        heads: heads
      }
    end

    AUTO_PREFIX = 'auto/'

    # The DAG condensed for display. One revision per keystroke is the log; a
    # person wants to see its shape. A maximal chain of revisions that is
    # topologically a line — each has one parent, that parent has no other
    # child, is not a branch head and is not the source of a merge — collapses
    # into one node when the chain is also on one branch, by one user, and (with
    # `gap_ms`) has no pause longer than gap_ms between consecutive revisions.
    # A revision with a second parent (a merge commit, or the last of a rebased
    # batch) may end a run but never continues one.
    #
    # `auto: false` folds the auto-branches a stale batch leaves behind
    # (ProjectFs.write_batch!: fork at the base, the batch as authored, then the
    # rebase onto the target whose last revision points back): their revisions
    # and heads are dropped and the rebased run is annotated instead —
    # `rebased: { branch:, count: }`. With `auto: true` they are ordinary
    # branches, for debugging the rebase path.
    #
    # Returns, oldest first, topologically ordered (parent runs before child runs):
    #   {
    #     path:, gap_ms:, auto:,
    #     heads:  [ { branch:, revision: } ],            # revision is a node id
    #     nodes:  [ { id:, first:, count:, branch:, user_id:, from:, to:,
    #                 kinds: { 'insertDataSingleLine' => n, ... }, rebased: nil | { branch:, count: } } ],
    #     edges:  [ { from:, to:, kind: 'parent' | 'second_parent' } ]   # run ids
    #   }
    # A node's id is its LAST revision, so a head's revision names its node.
    def condense(store, path, gap_ms: nil, auto: false)
      node = store.find(path)
      raise "no such file: #{path}" unless node

      branch_rows = node.branches.to_a
      name_of     = branch_rows.to_h { |b| [b.id, b.name] }
      auto_ids    = branch_rows.select { |b| b.name.start_with?(AUTO_PREFIX) }.map(&:id).to_set
      head_ids    = branch_rows.filter_map(&:head_revision_id).to_set

      cols = %i[id parent_id second_parent_id change_type branch_id user_id timestamp]
      revs = node.revisions.order(:timestamp, :id).pluck(*cols).map { |r| cols.zip(r).to_h }

      # Fold: count each auto-branch, keyed by its head (the revision a rebased
      # tail's second_parent names), then drop its revisions.
      folded = {}
      unless auto
        per_branch = Hash.new(0)
        revs.each { |r| per_branch[r[:branch_id]] += 1 if auto_ids.include?(r[:branch_id]) }
        branch_rows.each do |b|
          folded[b.head_revision_id] = { branch: b.name, count: per_branch[b.id] } if auto_ids.include?(b.id) && b.head_revision_id
        end
        revs.reject! { |r| auto_ids.include?(r[:branch_id]) }
        head_ids -= branch_rows.select { |b| auto_ids.include?(b.id) }.map(&:head_revision_id)
      end

      present  = revs.to_h { |r| [r[:id], r] }
      children = Hash.new(0)
      merge_src = Set.new
      revs.each do |r|
        children[r[:parent_id]] += 1 if r[:parent_id] && present.key?(r[:parent_id])
        merge_src << r[:second_parent_id] if r[:second_parent_id] && present.key?(r[:second_parent_id])
      end

      gap = gap_ms.to_i.positive? ? gap_ms.to_f / 1000.0 : nil
      runs   = []
      run_of = {}
      index  = {}
      topological(revs, present).each_with_index do |r, i|
        index[r[:id]] = i
        p   = r[:parent_id] && present[r[:parent_id]]
        run = p && run_of[p[:id]]
        joins = run && !run[:closed] && run[:last][:id] == p[:id] &&
                children[p[:id]] == 1 && !head_ids.include?(p[:id]) && !merge_src.include?(p[:id]) &&
                r[:branch_id] == p[:branch_id] && r[:user_id] == p[:user_id] &&
                (gap.nil? || (r[:timestamp] - p[:timestamp]) <= gap)
        unless joins
          run = { first: r, last: r, count: 0, kinds: Hash.new(0), closed: false }
          runs << run
        end
        run[:last]   = r
        run[:count] += 1
        run[:kinds][r[:change_type]] += 1
        run[:closed] = true if r[:second_parent_id]
        run_of[r[:id]] = run
      end
      # A node is named by its LAST revision, so order nodes by where that
      # revision sits topologically, not by where the run began: a run that
      # ends in a merge commit must come after the run holding its second
      # parent, even though it started earlier. Every edge source is a run's
      # last revision (forks and merge sources end runs), so this keeps each
      # edge's source before its target.
      runs.sort_by! { |run| index[run[:last][:id]] }

      nodes = runs.map do |run|
        f, l = run[:first], run[:last]
        {
          id: l[:id], first: f[:id], count: run[:count],
          branch: name_of[l[:branch_id]], user_id: l[:user_id],
          from: f[:timestamp]&.iso8601(3), to: l[:timestamp]&.iso8601(3),
          kinds: run[:kinds],
          rebased: l[:second_parent_id] ? folded[l[:second_parent_id]] : nil
        }
      end

      edges = runs.flat_map do |run|
        out = []
        f, l = run[:first], run[:last]
        out << { from: run_of[f[:parent_id]][:last][:id], to: l[:id], kind: 'parent' } if f[:parent_id] && run_of[f[:parent_id]]
        if l[:second_parent_id] && run_of[l[:second_parent_id]]
          out << { from: run_of[l[:second_parent_id]][:last][:id], to: l[:id], kind: 'second_parent' }
        end
        out
      end

      heads = branch_rows.sort_by(&:name).filter_map do |b|
        next if !auto && auto_ids.include?(b.id)
        next unless b.head_revision_id
        { branch: b.name, revision: b.head_revision_id }
      end

      { path: node.path, gap_ms: gap ? gap_ms.to_i : nil, auto: auto, heads: heads, nodes: nodes, edges: edges }
    end

    # `revs` in time order, with the rare child that sorts before a parent
    # (same timestamp, or a clock step) moved after it. Time order is kept
    # otherwise so a consumer laying rows out by position sees history in order.
    def topological(revs, present)
      done     = Set.new
      waiting  = Hash.new { |h, k| h[k] = [] }   # parent id => revs waiting on it
      order    = []
      pending_parent = lambda do |r|
        [r[:parent_id], r[:second_parent_id]].compact.find { |pid| present.key?(pid) && !done.include?(pid) }
      end
      revs.each do |r|
        if (w = pending_parent.call(r))
          waiting[w] << r
          next
        end
        stack = [r]
        until stack.empty?
          x = stack.pop
          next if done.include?(x[:id])
          if (w = pending_parent.call(x))
            waiting[w] << x
            next
          end
          order << x
          done << x[:id]
          waiting.delete(x[:id])&.reverse_each { |c| stack.push(c) }
        end
      end
      order
    end

    # Graphviz DOT for `dot -Tsvg graph.dot`. Merge-commit second parents are
    # drawn as dashed edges; branch heads are labelled boxes.
    def to_dot(store, path)
      g = dump(store, path)
      lines = ['digraph dbfs {', '  rankdir=BT;']
      g[:nodes].each do |n|
        label = "#{n[:change_type]}\\n#{n[:id][0, 8]}"
        lines << "  \"#{n[:id]}\" [label=\"#{label}\"];"
      end
      g[:edges].each do |e|
        style = e[:kind] == 'second_parent' ? ' [style=dashed]' : ''
        lines << "  \"#{e[:from]}\" -> \"#{e[:to]}\"#{style};"
      end
      g[:heads].each do |h|
        next unless h[:revision]
        lines << "  \"head_#{h[:branch]}\" [label=\"#{h[:branch]}\", shape=box];"
        lines << "  \"head_#{h[:branch]}\" -> \"#{h[:revision]}\" [style=bold];"
      end
      lines << '}'
      lines.join("\n")
    end
  end
end
