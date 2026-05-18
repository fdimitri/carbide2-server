class Project < ActiveRecord::Base
  belongs_to :user, optional: true
  has_many :terminal_sessions, dependent: :destroy

  validates :name, presence: true
end
