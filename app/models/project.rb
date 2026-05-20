class Project < ActiveRecord::Base
  belongs_to :user, optional: true
  has_many :chat_channels, dependent: :destroy
  has_many :chat_messages, through: :chat_channels
  has_many :directory_entries, dependent: :destroy
  has_one  :project_setting,   dependent: :destroy

  validates :name, presence: true
end
