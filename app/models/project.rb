class Project < ActiveRecord::Base
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :chat_channels, dependent: :destroy
  has_many :chat_messages, through: :chat_channels
  has_many :directory_entries, dependent: :destroy
  has_one  :project_setting,   dependent: :destroy

  validates :name, presence: true

  after_create :ensure_project_setting!

  # Default per-project workspace directory inside the shared projects volume.
  # Worker, FsLoader, VfsFlusher, ProjectContainer all agree on this layout.
  PROJECTS_ROOT = ENV.fetch('PROJECTS_ROOT', '/srv/projects').freeze

  # A workspace pod hosts exactly ONE project (Model B: Workspace == pod ==
  # project). This returns that single canonical project, creating it on
  # first call. Its primary key is LOCAL and unrelated to the control-plane
  # workspace id — never look a project up by the control-plane id.
  def self.canonical
    order(:id).first || create!(name: ENV.fetch('WORKSPACE_NAME', 'workspace'))
  end

  def default_root_path
    File.join(PROJECTS_ROOT, id.to_s)
  end

  # Creates the project_setting row (if missing) with a sane root_path
  # and ensures the on-disk directory exists. Idempotent.
  def ensure_project_setting!
    setting = project_setting || build_project_setting
    setting.root_path = default_root_path if setting.root_path.blank?
    setting.save! if setting.changed? || setting.new_record?
    FileUtils.mkdir_p(setting.root_path) rescue nil
    setting
  end
end
