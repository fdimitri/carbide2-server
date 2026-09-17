class Project < ActiveRecord::Base
  # Raised when a workspace pod would create its canonical project without the
  # control-owned workspace uuid. Control hands it down as
  # WORKSPACE_PROJECT_UUID; without it the root path has no stable name, and the
  # shell pod (which names the same directory in subPath) cannot address it.
  # A boot error, not a validation: nothing downstream can invent the value.
  class WorkspaceUuidMissing < StandardError; end

  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :chat_channels, dependent: :destroy
  has_many :chat_messages, through: :chat_channels
  # DBFS v2 nodes. No dependent: option — the file_nodes foreign key cascades
  # in the database, and application code never destroys a node (tombstones).
  has_many :file_nodes
  has_many :browser_sessions,  dependent: :destroy
  has_one  :project_setting,   dependent: :destroy

  validates :name, presence: true

  after_create :ensure_project_setting!

  # Default per-project workspace directory inside the shared projects volume.
  # Worker, FsLoader, VfsFlusher, and the operator's shell builder all agree on
  # this layout.
  PROJECTS_ROOT = ENV.fetch('PROJECTS_ROOT', '/srv/projects').freeze

  # A workspace pod hosts exactly ONE project (Model B: Workspace == pod ==
  # project). This returns that single canonical project, creating it on
  # first call. Its primary key is LOCAL and unrelated to the control-plane
  # workspace id — never look a project up by the control-plane id.
  #
  # projects.uuid is a MIRROR of the control-owned workspace identity, handed
  # to the pod as WORKSPACE_PROJECT_UUID. It is stamped here at creation time
  # only; it is never derived from a user token or self-assigned on validation.
  def self.canonical
    order(:id).first || begin
      uuid = ENV['WORKSPACE_PROJECT_UUID'].presence
      raise WorkspaceUuidMissing, 'Workspace UUID not defined by control' if uuid.blank?

      create!(
        name: ENV.fetch('WORKSPACE_NAME', 'workspace'),
        uuid: uuid,
      )
    end
  end

  # Keyed by uuid, not id: the uuid is the control-owned workspace identity
  # (== ControlProject.uuid), so the operator can name this same directory in
  # the shell pod's subPath without knowing this database's primary keys.
  def default_root_path
    raise WorkspaceUuidMissing, 'Workspace UUID not defined by control' if uuid.blank?

    File.join(PROJECTS_ROOT, uuid)
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
