# ProjectMembership — join table granting a user access to a project.
class ProjectMembership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  validates :user_id, uniqueness: { scope: :project_id }
end
