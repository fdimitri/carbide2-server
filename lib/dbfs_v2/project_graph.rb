# frozen_string_literal: true
module DbfsV2
  # ProjectGraph — the project's branches as a rail graph (ADR-042).
  #
  # One lane per project branch; a node is a run of activity on that branch
  # (revisions and file events, one author, no pause longer than gap_ms, and
  # never across a fork or merge point). Edges: the run before on the same
  # branch (`parent`), the parent branch's run at the fork into the child's
  # first run (`parent`, so the child's lane leaves the parent's), and the
  # source's run at a merge into the target's run that holds it
  # (`second_parent`). The shape is the file DAG's condensed shape
  # (Graph.condense) so the client draws both with one rail layout.
  #
  # Returns, oldest first (parents before children):
  #   { gap_ms:,
  #     heads:    [ { branch:, revision: } ],            # revision is a node id
  #     branches: [ { id:, name:, forked_from:, fork_seq:, base_seq:, deleted:, materialized: } ],
  #     nodes:    [ { id:, first:, count:, branch:, user_id:, from:, to:, seq:, first_seq:,
  #                   kinds: { 'edit' => n, 'created' => n, 'renamed' => n, 'deleted' => n,
  #                            'restored' => n, 'forked' => 1, 'merged' => n } } ],
  #     edges:    [ { from:, to:, kind: 'parent' | 'second_parent' } ] }
  module ProjectGraph
    module_function

    def build(store, gap_ms: nil)
      pid      = store.project_id
      branches = ProjectBranch.where(project_id: pid).order(:seq, :created_at).to_a
      by_id    = branches.index_by(&:id)
      main     = branches.find(&:main?)
      gap      = gap_ms && gap_ms.to_i.positive? ? gap_ms.to_i / 1000.0 : nil

      items = Hash.new { |h, k| h[k] = [] }        # branch_id => [{ seq:, user_id:, ts:, kind:, cut: }]

      Revision.joins(:branch).where(project_id: pid)
              .pluck('branches.project_branch_id', :seq, 'revisions.user_id', :timestamp).each do |bid, seq, uid, ts|
        items[bid || main&.id] << { seq: seq, user_id: uid, ts: ts, kind: 'edit' }
      end
      FileEvent.where(project_id: pid).pluck(:project_branch_id, :seq, :user_id, :created_at, :kind).each do |bid, seq, uid, ts, kind|
        items[bid || main&.id] << { seq: seq, user_id: uid, ts: ts, kind: kind }
      end
      branches.each do |b|
        next if b.main?
        items[b.id] << { seq: b.fork_seq || b.seq, user_id: b.user_id, ts: b.created_at, kind: 'forked', cut: true }
      end
      merges = ProjectMergeRecord.where(project_id: pid).order(:seq).to_a
      merges.each do |m|
        items[m.target_id] << { seq: m.seq, user_id: m.user_id, ts: m.created_at, kind: 'merged', cut: true }
      end

      # Seqs a run may not span: a child's fork point on the parent, a merge's
      # seq on its source. The run holding one ends there.
      cuts = Hash.new { |h, k| h[k] = Set.new }
      branches.each { |b| cuts[b.forked_from_id] << (b.fork_seq || b.seq) if b.forked_from_id }
      merges.each { |m| cuts[m.source_id] << m.seq }

      runs_of = {}                                  # branch_id => [run]
      items.each do |bid, list|
        list.sort_by! { |i| [i[:seq], i[:kind] == 'forked' ? 0 : 1] }
        runs = []
        list.each do |i|
          cur = runs.last
          # Items at one seq are one operation (a subtree delete, a merge's
          # last write and its record): they never split, so a node id
          # (branch@seq) is unique.
          same_op = cur && cur[:last] == i[:seq]
          # A fork or merge point between the run's last item and this one
          # (the point itself may be a seq with no item on this branch).
          crossed = cur && cuts[bid].any? { |c| c >= cur[:last] && c < i[:seq] }
          fits = same_op ||
                 (cur && !cur[:closed] && !crossed && !i[:cut] && cur[:user_id] == i[:user_id] &&
                  (gap.nil? || cur[:to].nil? || i[:ts].nil? || (i[:ts] - cur[:to]) <= gap))
          if fits
            cur[:count] += 1
            cur[:last]   = i[:seq]
            cur[:to]     = i[:ts] if i[:ts]
            cur[:kinds][i[:kind]] = cur[:kinds].fetch(i[:kind], 0) + 1
          else
            runs << { branch_id: bid, first: i[:seq], last: i[:seq], count: 1, user_id: i[:user_id],
                      from: i[:ts], to: i[:ts], kinds: { i[:kind] => 1 }, closed: false }
          end
          runs.last[:closed] = true if i[:cut]
        end
        runs_of[bid] = runs
      end

      node_id = ->(run) { "#{run[:branch_id]}@#{run[:last]}" }
      # The run on `bid` that holds or is the latest before `seq`.
      run_at = lambda do |bid, seq|
        rs = runs_of[bid] || []
        rs.find { |r| r[:first] <= seq && seq <= r[:last] } || rs.select { |r| r[:last] <= seq }.last
      end
      # The run on `bid` that holds or is the first after `seq`.
      run_from = lambda do |bid, seq|
        rs = runs_of[bid] || []
        rs.find { |r| r[:first] <= seq && seq <= r[:last] } || rs.find { |r| r[:first] >= seq }
      end

      edges = []
      runs_of.each do |bid, runs|
        runs.each_cons(2) { |a, b| edges << { from: node_id[a], to: node_id[b], kind: 'parent' } }
        b = by_id[bid]
        next unless b && b.forked_from_id && runs.any?
        if (p = run_at[b.forked_from_id, b.fork_seq || b.seq])
          edges << { from: node_id[p], to: node_id[runs.first], kind: 'parent' }
        end
      end
      merges.each do |m|
        s = run_at[m.source_id, m.seq]
        t = run_from[m.target_id, m.seq]
        edges << { from: node_id[s], to: node_id[t], kind: 'second_parent' } if s && t
      end

      nodes = runs_of.values.flatten.sort_by { |r| [r[:last], r[:first]] }.map do |r|
        { id: node_id[r], first: "#{r[:branch_id]}@#{r[:first]}", count: r[:count],
          branch: by_id[r[:branch_id]]&.name, branch_id: r[:branch_id], user_id: r[:user_id],
          from: r[:from]&.iso8601(3), to: r[:to]&.iso8601(3),
          seq: r[:last], first_seq: r[:first], kinds: r[:kinds] }
      end

      heads = branches.reject(&:deleted?).filter_map do |b|
        last = (runs_of[b.id] || []).last
        last && { branch: b.name, revision: node_id[last] }
      end

      { gap_ms: gap_ms&.to_i, heads: heads, branches: branches.map(&:to_h), nodes: nodes, edges: edges }
    end
  end
end
