# frozen_string_literal: true
module DbfsV2
  # Events — the append-only existence/identity log (ADR-042).
  #
  # Store#create_*, #delete, #restore and #move each record one operation:
  # one Clock tick, one or more FileEvent rows sharing that seq (a subtree
  # delete or a folder move is one operation, so no cut lands inside it).
  #
  # The fold (ProjectState) reads: the newest event with seq <= S decides
  # whether the node exists (created/restored/renamed => yes, deleted => no)
  # and what its path is.
  module Events
    module_function

    # rows: [{ file_node_id:, path:, ftype:, from_path: (renamed only) }]
    # Returns the seq the operation took.
    def record!(project_id, kind, rows, user_id: nil)
      raise ArgumentError, "unknown event kind #{kind}" unless FileEvent::KINDS.include?(kind.to_s)
      rows = Array(rows)
      return nil if rows.empty?

      ActiveRecord::Base.transaction do
        seq = Clock.tick!(project_id)
        now = Time.now.utc
        FileEvent.insert_all!(rows.map do |r|
          {
            project_id:   project_id,
            seq:          seq,
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
    def record_node!(project_id, kind, node, user_id: nil, from_path: nil)
      record!(project_id, kind,
              [{ file_node_id: node.id, path: node.path, ftype: node.ftype, from_path: from_path }],
              user_id: user_id)
    end
  end
end
