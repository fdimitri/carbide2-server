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

  # Per-agent tool-call loop budget (orchestration, not a sampling param).
  # nil = use the worker's MAX_TURNS default.
  validates :max_turns, numericality: { only_integer: true, greater_than: 0,
                                        less_than_or_equal_to: 100 },
                        allow_nil: true

  scope :enabled, -> { where(enabled: true) }

  has_many :agent_conversations, dependent: :restrict_with_error

  ROLES = %w[general coder reviewer safety router].freeze

  # Weekdays a peak_hours window may name. Stored lowercase; matched against
  # the weekday in the WINDOW'S OWN zone (see the client's peakHours.js).
  WEEKDAYS = %w[sun mon tue wed thu fri sat].freeze

  # "HH:MM" wall clock, 00:00-23:59, in the window's own zone.
  TIME_OF_DAY = /\A([01]\d|2[0-3]):[0-5]\d\z/

  validate :peak_hours_windows_are_valid

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

  # Peak-hours windows as an array of hashes regardless of how the DB returned
  # the column (SQLite/Postgres differ on json columns, same as allowed_tools).
  #
  # Each window is stored AS ENTERED: the days it covers, its times, and the
  # timezone those times are in.
  #   { "days" => [weekday…], "start" => "HH:MM", "end" => "HH:MM", "tz" => "America/New_York" }
  # An empty `days` means every day. `tz` absent means "UTC" (windows written
  # before the field existed). Times are NOT converted to UTC on write: a
  # recurring window is anchored to a local clock, so converting it would make
  # it drift across a DST boundary and would discard the clock the user meant.
  def peak_hours_windows
    raw = case peak_hours
          when String then (JSON.parse(peak_hours) rescue [])
          when Array  then peak_hours
          else []
          end
    return [] unless raw.is_a?(Array)
    raw.select { |w| w.is_a?(Hash) }.map do |w|
      w = w.transform_keys(&:to_s)
      {
        'days'  => Array(w['days']).map { |d| d.to_s.downcase }.select { |d| WEEKDAYS.include?(d) },
        'start' => w['start'].to_s,
        'end'   => w['end'].to_s,
        'tz'    => w['tz'].to_s.strip,
      }
    end
  end

  # Assign peak hours from client input. Accepts an array of hashes or a JSON
  # string; nil clears the field. Anything else is stored as-is so
  # #peak_hours_windows_are_valid rejects it rather than silently coercing a
  # malformed payload into "no peak hours".
  def peak_hours=(value)
    super(
      case value
      when nil    then []
      when String then (JSON.parse(value) rescue value)
      else value
      end
    )
  end

  # Authorization header value or nil. Worker passes this through verbatim.
  def auth_header
    return nil if api_key.blank?
    "Bearer #{api_key}"
  end

  # True if this agent may use the shell_exec tool. The two-layer gate
  # (this flag AND allowed_tools containing 'shell_exec') is intentional —
  # the column makes the dangerous capability auditable as a single bool,
  # while allowed_tools controls which subset is exposed in any given
  # request.
  def shell_exec_allowed?
    !!shell_exec_enabled && allowed_tool_slugs.include?('shell_exec')
  end

  private

  # Enforce the documented shape: days ⊆ WEEKDAYS, start/end are HH:MM wall
  # clock, tz is a zone the runtime actually knows, and the window is
  # non-degenerate. Anything else is a client bug worth rejecting rather than
  # silently normalizing away.
  #
  # The tz is validated against TZInfo (the tz database ActiveSupport already
  # depends on) rather than an allow-list here: the client offers a longer list
  # than any hand-maintained one would match, and an unknown zone would make the
  # window untranslatable at evaluation time rather than merely wrong.
  def peak_hours_windows_are_valid
    raw = case peak_hours
          when String then (JSON.parse(peak_hours) rescue nil)
          when Array  then peak_hours
          else nil
          end
    if raw.nil? || !raw.is_a?(Array)
      errors.add(:peak_hours, 'must be an array of windows')
      return
    end

    raw.each_with_index do |w, i|
      unless w.is_a?(Hash)
        errors.add(:peak_hours, "window #{i} must be an object")
        next
      end
      w = w.transform_keys(&:to_s)

      days = Array(w['days'])
      bad  = days.map { |d| d.to_s.downcase } - WEEKDAYS
      errors.add(:peak_hours, "window #{i} has invalid day(s): #{bad.join(', ')}") if bad.any?

      start_t = w['start'].to_s
      end_t   = w['end'].to_s
      unless start_t.match?(TIME_OF_DAY)
        errors.add(:peak_hours, "window #{i} start must be HH:MM")
      end
      unless end_t.match?(TIME_OF_DAY)
        errors.add(:peak_hours, "window #{i} end must be HH:MM")
      end
      if start_t.match?(TIME_OF_DAY) && start_t == end_t
        errors.add(:peak_hours, "window #{i} start and end are the same")
      end

      tz = w['tz'].to_s.strip
      if tz.present? && !known_time_zone?(tz)
        errors.add(:peak_hours, "window #{i} has unknown timezone: #{tz}")
      end
    end
  end

  # True when the runtime can resolve `tz` as an IANA zone name. An empty value
  # is allowed and means UTC (see #peak_hours_windows).
  def known_time_zone?(tz)
    ActiveSupport::TimeZone[tz].present? || TZInfo::Timezone.get(tz).present?
  rescue TZInfo::InvalidTimezoneIdentifier
    false
  end
end
