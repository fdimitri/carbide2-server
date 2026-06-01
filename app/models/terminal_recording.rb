# TerminalRecording — index row for an on-disk asciinema cast file.
# Copyright (C) 2025 Carbide2 contributors. GPLv3.
class TerminalRecording < ApplicationRecord
  belongs_to :project
  belongs_to :created_by, class_name: 'User', optional: true

  STATUSES = %w[recording stopped crashed].freeze
  validates :status, inclusion: { in: STATUSES }
  validates :terminal_id, :file_path, :started_at, presence: true

  scope :stopped, -> { where(status: 'stopped') }
  scope :for_project, ->(pid) { where(project_id: pid).order(started_at: :desc) }

  # Resolve the absolute path on disk for this recording. The :file_path
  # column stores the path relative to TerminalRecorder::RECORDINGS_ROOT so
  # the storage location can be moved without a data migration.
  #
  # Use __dir__ as the fallback so this method works inside the EventMachine
  # worker process (where Rails is not booted and Rails.root is undefined).
  # __dir__ is app/models/, so three levels up is the Rails root.
  DEFAULT_RECORDINGS_ROOT = File.expand_path('../../../storage/terminal_recordings', __dir__).freeze

  def absolute_file_path
    base = ENV.fetch('TERMINAL_RECORDINGS_ROOT', DEFAULT_RECORDINGS_ROOT)
    File.join(base, file_path)
  end

  # Duration of the recording in seconds, or nil if still in progress.
  def duration_seconds
    return nil unless ended_at && started_at
    (ended_at - started_at).to_f
  end

  def to_list_entry
    {
      id:            id,
      project_id:    project_id,
      terminal_id:   terminal_id,
      terminal_name: terminal_name,
      cols:          cols,
      rows:          rows,
      started_at:    started_at,
      ended_at:      ended_at,
      duration:      duration_seconds,
      byte_count:    byte_count,
      status:        status,
      created_by:    created_by_id,
    }
  end
end
