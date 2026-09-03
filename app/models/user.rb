# Workspace-local mirror of a control user (ADR-015/023). The pod never
# authenticates locally — control mints the tokens; this row only mirrors
# identity, keyed by control_uuid. There is no password on this side.
class User < ActiveRecord::Base
  # RFC 4122 all-zeros UUID, reserved and never minted by control, so the
  # sentinel cannot collide with a real mirror user.
  SYSTEM_UUID = '00000000-0000-0000-0000-000000000000'.freeze

  has_many :project_memberships, dependent: :destroy
  has_many :projects,            through:   :project_memberships
  has_many :chat_messages, dependent: :nullify
  has_many :browser_sessions, dependent: :destroy
  has_one  :user_preference, dependent: :destroy

  after_create :create_user_preference

  # The sentinel user owning unattributed (system/import) writes. Resolved
  # idempotently; see FsLoader and DirectoryEntry.create_file!.
  def self.system
    find_or_create_by!(control_uuid: SYSTEM_UUID)
  end

  # Canonical display-name resolution. Single source of truth so every call
  # site (worker broadcast, agent replay, legacy token minting) agrees on the
  # same precedence: username > first+last > email prefix. When the control
  # plane later syncs a real display_name field (see #61), prefer it here and
  # all consumers update for free.
  def display_name
    pref = user_preference
    return pref.username if pref&.username.present?

    full = [pref&.first_name, pref&.last_name].compact.join(' ').strip
    return full if full.present?

    email.to_s.split('@').first.presence || "user #{id}"
  end
end
