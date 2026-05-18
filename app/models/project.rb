class Project < ActiveRecord::Base
  belongs_to :user, optional: true
  has_many :chat_channels, dependent: :destroy
  has_many :chat_messages, through: :chat_channels

  validates :name, presence: true
end
