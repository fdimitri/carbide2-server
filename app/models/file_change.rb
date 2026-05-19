# FileChange — append-only edit log for a DirectoryEntry file.
#
# change_type values (camelCase, matching WebSocket protocol):
#   setContents           — replace entire file content (used on first load / external edit)
#   insertDataSingleLine  — insert text at (start_line, start_char)
#   deleteDataSingleLine  — delete text at (start_line, start_char)
#   insertDataMultiLine   — insert multi-line block starting at (start_line, start_char)
#   deleteDataMultiLine   — delete from (start_line, start_char) to (end_line, end_char)
#
# revision is assigned as file_changes.count for this entry at insert time,
# providing a per-file monotonically increasing sequence number.
class FileChange < ApplicationRecord
  belongs_to :directory_entry
  belongs_to :user, optional: true

  VALID_TYPES = %w[
    setContents
    insertDataSingleLine
    deleteDataSingleLine
    insertDataMultiLine
    deleteDataMultiLine
  ].freeze

  validates :change_type, inclusion: { in: VALID_TYPES }
  validates :revision, numericality: { greater_than_or_equal_to: 0 }

  # Append a new change for a directory entry, assigning the next revision.
  # Must be called inside a transaction when concurrent writes are possible.
  def self.append!(directory_entry_id:, user_id: nil, change_type:, change_data: nil,
                   start_line: 0, start_char: 0, end_line: nil, end_char: nil)
    rev = where(directory_entry_id: directory_entry_id).count
    create!(
      directory_entry_id: directory_entry_id,
      user_id:            user_id,
      change_type:        change_type,
      change_data:        change_data,
      start_line:         start_line,
      start_char:         start_char,
      end_line:           end_line,
      end_char:           end_char,
      revision:           rev
    )
  end
end
