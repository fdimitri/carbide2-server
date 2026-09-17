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
