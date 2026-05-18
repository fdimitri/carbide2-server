class ChatMessage < ActiveRecord::Base
  belongs_to :chat_channel
  belongs_to :user, optional: true

  validates :text, presence: true
  validates :name, presence: true
end