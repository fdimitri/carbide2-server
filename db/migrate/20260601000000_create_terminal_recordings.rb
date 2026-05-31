class CreateTerminalRecordings < ActiveRecord::Migration[8.1]
  def change
    create_table :terminal_recordings do |t|
      t.references :project, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }, null: true

      # The in-memory terminal id at the time of recording (terminals are
      # ephemeral and don't have a persistent FK, so we just snapshot the
      # int + a human-readable name for display).
      t.integer  :terminal_id, null: false
      t.string   :terminal_name

      # asciinema v2 cast file on disk. Path is relative to the worker's
      # recordings root (see TerminalRecorder::RECORDINGS_ROOT). Format:
      #   header line: {"version":2,"width":W,"height":H,"timestamp":epoch}
      #   data lines:  [elapsed_seconds, "o", "<bytes>"]
      t.string   :file_path,   null: false

      # Snapshot of geometry at start so the player knows what to size to.
      t.integer  :cols, null: false, default: 80
      t.integer  :rows, null: false, default: 24

      t.datetime :started_at,  null: false
      t.datetime :ended_at     # nil while recording is in progress
      t.bigint   :byte_count,  null: false, default: 0
      t.string   :status,      null: false, default: 'recording'  # recording|stopped|crashed

      t.timestamps
    end

    add_index :terminal_recordings, [:project_id, :started_at]
  end
end
