# Agent — a configured LLM persona with an OpenAI-compatible endpoint, a
# system prompt, and an allowlist of tools it can call. One row per agent.
# Worker's AgentSession loads these by slug; the chat UI lists enabled
# ones grouped by role.
#
# Why a table instead of YAML/env:
# - Admins can add/edit agents at runtime without redeploying the worker.
# - Per-agent tool allowlists are first-class data, queryable and joinable.
# - Future per-project agent overrides (e.g. project-X may only invoke the
#   safety-guard agent) become a join, not config-file gymnastics.
#
# The api_key column is encrypted at rest. For local/LAN model servers
# (LM Studio, llama.cpp, Ollama) leave it nil.
class Agent < ApplicationRecord
  # TODO: enable Rails 8 attribute encryption for api_key once cluster
  # provisioning sets active_record.encryption.primary_key. For now api_key
  # is stored plaintext; OK for local model servers (LM Studio, llama.cpp,
  # Ollama) which take no key. DO NOT put a real hosted-provider key in
  # this column until encryption is on.
  # encrypts :api_key

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9][a-z0-9_-]*\z/,
                             message: 'must be lowercase alphanumeric with - or _' }
  validates :name,         presence: true
  validates :provider_url, presence: true,
                           format: { with: %r{\Ahttps?://}, message: 'must be an http(s) URL' }
  validates :model,        presence: true
  validates :role,         presence: true

  scope :enabled, -> { where(enabled: true) }

  ROLES = %w[general coder reviewer safety router].freeze

  # Allowed tool slugs as a plain array regardless of how the DB returned the
  # column (SQLite returns a String for json columns, Postgres returns Array).
  def allowed_tool_slugs
    case allowed_tools
    when Array  then allowed_tools.map(&:to_s)
    when String then (JSON.parse(allowed_tools) rescue [])
    else []
    end
  end

  # Sampling params, similarly normalized.
  def sampling_params
    case sampling
    when Hash   then sampling
    when String then (JSON.parse(sampling) rescue {})
    else {}
    end
  end

  # Authorization header value or nil. Worker passes this through verbatim.
  def auth_header
    return nil if api_key.blank?
    "Bearer #{api_key}"
  end
end
