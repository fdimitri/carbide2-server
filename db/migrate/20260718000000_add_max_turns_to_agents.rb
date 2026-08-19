class AddMaxTurnsToAgents < ActiveRecord::Migration[8.1]
  def change
    # Per-agent tool-call loop budget. Nullable: nil means "use the worker's
    # MAX_TURNS default". Orchestration only — never sent to the model API.
    add_column :agents, :max_turns, :integer
  end
end
