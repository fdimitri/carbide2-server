# Minimal User model placeholder for pre-alpha
class User < ActiveRecord::Base
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable, :trackable

  has_many :project_memberships, dependent: :destroy
  has_many :projects,            through:   :project_memberships
  has_many :chat_messages, dependent: :nullify
  has_many :browser_sessions, dependent: :destroy
  has_one  :user_preference, dependent: :destroy

  after_create :create_user_preference

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
