class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents do |t|
      # Stable string identifier (e.g. "coder", "reviewer", "safety-guard"),
      # used by tools/UI to ask for a specific agent without leaking DB ids.
      t.string  :slug,           null: false
      t.string  :name,           null: false
      t.string  :description

      # OpenAI-compatible chat endpoint, e.g.
      #   http://192.168.1.10:1234/v1   (LM Studio on the LAN)
      #   http://ollama.carbide-system.svc.cluster.local:11434/v1
      # We store the base URL; AgentSession appends /chat/completions.
      t.string  :provider_url,   null: false
      # Model name as the server expects it (e.g. "qwen2.5-coder-32b-instruct").
      t.string  :model,          null: false
      # Optional API key. nil/empty means no Authorization header (LM Studio,
      # local llama.cpp, Ollama default). For hosted providers, store the
      # secret here. Encrypted at rest via Rails 8 encrypted attributes.
      t.text    :api_key

      # The agent's role identity. Sent as the first 'system' message.
      t.text    :system_prompt,  null: false, default: ''

      # JSON-encoded list of tool slugs this agent is allowed to call. Empty
      # means "no tools, chat only". The actual tool definitions live in
      # AgentTools (worker-side registry); this is the per-agent allowlist.
      t.json    :allowed_tools,  null: false, default: []

      # Sampling knobs. Stored as JSON so we can add more without a migration
      # (top_p, presence_penalty, repeat_penalty, etc.). Common defaults:
      #   { "temperature": 0.2, "max_tokens": 2048 }
      t.json    :sampling,       null: false, default: {}

      # Purpose tag — UI hint and grouping. Free-form for now; expected values:
      #   "general", "coder", "reviewer", "safety", "router".
      t.string  :role,           null: false, default: 'general'

      # When false, the agent exists but isn't selectable from the chat UI.
      # Useful for staging a new agent without exposing it.
      t.boolean :enabled,        null: false, default: true

      t.timestamps
    end

    add_index :agents, :slug, unique: true
    add_index :agents, :role
    add_index :agents, :enabled
  end
end
