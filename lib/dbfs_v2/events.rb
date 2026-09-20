# frozen_string_literal: true
module DbfsV2
  # Events — notifications for a path op (explorer / seq clock).
  #
  # Store#create_*, #delete, #restore and #move each record one operation:
  # the project node's seq, one or more FileEvent rows sharing that seq (a
  # subtree delete or a folder move is one operation). Pass `seq:` from the
  # node so the cut S names the tree and the notifications together. The
  # project tree is the DAG, not a fold of these rows.
  module Events
    module_function

    # rows: [{ file_node_id:, path:, ftype:, from_path: (renamed only) }]
    # `branch`: the ProjectBranch whose existence log this is (nil = main).
    # `seq`: the project node's seq when this is a path op; ticks if omitted.
    # Returns the seq the operation took.
    def record!(project_id, kind, rows, user_id: nil, branch: nil, seq: nil)
      raise ArgumentError, "unknown event kind #{kind}" unless FileEvent::KINDS.include?(kind.to_s)
      rows = Array(rows)
      return nil if rows.empty?

      pb_id = (branch || ProjectBranch.main_for(project_id)).id
      ActiveRecord::Base.transaction do
        seq ||= Clock.tick!(project_id)
        now = Time.now.utc
        FileEvent.insert_all!(rows.map do |r|
          {
            project_id:        project_id,
            project_branch_id: pb_id,
            seq:               seq,
            file_node_id: r.fetch(:file_node_id),
            kind:         kind.to_s,
            path:         r.fetch(:path),
            from_path:    r[:from_path],
            ftype:        r[:ftype] || 'file',
            user_id:      user_id,
            created_at:   now
          }
        end)
        seq
      end
    end

    # Convenience: one event for one node.
    def record_node!(project_id, kind, node, user_id: nil, from_path: nil, branch: nil)
      record!(project_id, kind,
              [{ file_node_id: node.id, path: node.path, ftype: node.ftype, from_path: from_path }],
              user_id: user_id, branch: branch)
    end
  end
end
