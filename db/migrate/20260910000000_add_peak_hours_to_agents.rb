# Per-agent "peak hours" windows — periods of the week when the upstream
# provider is rate-limited, slow, or billed at a premium. Stored so the
# client can warn before a request lands in a bad window.
#
# ALL TIMES ARE UTC. start/end are "HH:MM" wall-clock in UTC and `days` are
# UTC weekdays; never local time, never a server-local zone. A window is read
# against the UTC clock (getUTCDay/getUTCHours client-side), so the stored
# value means the same thing regardless of where the worker or the browser
# runs. An empty array means "no peak hours configured" for this agent.
#
# Shape: [{ "days" => ["mon".."sun"], "start" => "HH:MM", "end" => "HH:MM" }]
# `days` omitted/empty => every day. end < start => the window crosses
# midnight and is matched against the UTC day of its start.
class AddPeakHoursToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :peak_hours, :json, default: [], null: false
  end
end
