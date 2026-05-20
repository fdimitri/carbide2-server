# Minimal User model placeholder for pre-alpha
class User < ActiveRecord::Base
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable, :trackable

  has_many :projects, dependent: :destroy
  has_many :chat_messages, dependent: :nullify
  has_one  :user_preference, dependent: :destroy

  after_create :create_user_preference
end
