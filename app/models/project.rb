class Project < ActiveRecord::Base
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :chat_channels, dependent: :destroy
  has_many :chat_messages, through: :chat_channels
  has_many :directory_entries, dependent: :destroy
  has_one  :project_setting,   dependent: :destroy

  validates :name, presence: true
end
