# frozen_string_literal: true
module DbfsV2
  # Clock — the per-project sequence (ADR-042).
  #
  # One row per project in project_clocks. `tick!` bumps it inside whatever
  # transaction the caller holds; the UPDATE takes the row lock, which is held
  # until that transaction commits, so the next writer cannot draw a value
  # until the previous one is durable. Hence seq order IS commit order — which a
  # Postgres SEQUENCE would not give (a transaction that drew 41 may commit
  # after the one that drew 42).
  #
  # Every revision ticks once (Revision#stamp_seq). Every filesystem operation
  # that changes existence or identity ticks once and stamps all of its events
  # with the same value, so no project state falls inside an operation.
  module Clock
    module_function

    TICK_SQL = <<~SQL.squish
      INSERT INTO project_clocks (project_id, seq) VALUES (%<project_id>d, 1)
      ON CONFLICT (project_id) DO UPDATE SET seq = project_clocks.seq + 1
      RETURNING seq
    SQL

    # Next value for `project_id`. Call inside the writing transaction.
    def tick!(project_id)
      raise ArgumentError, 'project_id required' if project_id.nil?
      ActiveRecord::Base.connection.select_value(format(TICK_SQL, project_id: Integer(project_id))).to_i
    end

    # The current value: the seq of the newest thing that happened. 0 when the
    # project has never been written to since the clock existed.
    def now(project_id)
      ActiveRecord::Base.connection
                        .select_value("SELECT seq FROM project_clocks WHERE project_id = #{Integer(project_id)}")
                        .to_i
    end
  end
end
