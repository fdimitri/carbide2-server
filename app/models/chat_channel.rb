class ChatChannel < ActiveRecord::Base
  belongs_to :project
  has_many :chat_messages, dependent: :destroy

  validates :name, presence: true
  validates :name, uniqueness: { scope: :project_id }
end
