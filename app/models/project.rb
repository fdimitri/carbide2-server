class Project < ActiveRecord::Base
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :chat_channels, dependent: :destroy
  has_many :chat_messages, through: :chat_channels
  has_many :directory_entries, dependent: :destroy
  has_many :browser_sessions,  dependent: :destroy
  has_one  :project_setting,   dependent: :destroy

  validates :name, presence: true

  after_create :ensure_project_setting!

  # Stable control-owned project identity (== workspace uuid under 1:1).
  # The local integer PK never leaves the pod; the token/mirror use this uuid.
  before_validation :assign_uuid, on: :create

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

  private

  def assign_uuid
    # The canonical project mirrors control's workspace uuid (== project uuid
    # under 1:1), handed to the pod at launch. Only the canonical project gets
    # it — a future second project must be pushed from control with its OWN
    # uuid, never derived from the workspace env. NULL stays NULL: the pod does
    # not fabricate stable identity control knows nothing about.
    return unless canonical?
    self.uuid ||= ENV['WORKSPACE_PROJECT_UUID'].presence
  end

  def canonical?
    id == self.class.canonical.id
  rescue ActiveRecord::RecordNotFound
    false
  end
end
