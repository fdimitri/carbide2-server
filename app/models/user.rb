# Minimal User model placeholder for pre-alpha
class User < ActiveRecord::Base
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable, :trackable

  has_many :project_memberships, dependent: :destroy
  has_many :projects,            through:   :project_memberships
  has_many :chat_messages, dependent: :nullify
  has_one  :user_preference, dependent: :destroy

  after_create :create_user_preference
end
