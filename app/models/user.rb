# Minimal User model placeholder for pre-alpha
class User < ActiveRecord::Base
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable, :trackable

  has_many :projects, dependent: :destroy
  has_many :terminal_sessions, foreign_key: :owner_id, dependent: :destroy
end
