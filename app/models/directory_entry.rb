# DirectoryEntry — virtual filesystem node for a project.
#
# ftype:   'file' | 'folder'
# srcpath: canonical path within project, e.g. '/src/app.rb'
# owner_id: id of the parent DirectoryEntry (nil for root)
#
# Mirrors the DirectoryEntry/DirectoryEntryCommandProcessor/DirectoryEntryHelper
# design from the original CARBIDE, adapted for Rails 8 conventions and
# multi-project support (project_id added to every entry).
class DirectoryEntry < ApplicationRecord
  belongs_to :project
  belongs_to :owner,      class_name: 'DirectoryEntry', optional: true
  belongs_to :created_by, class_name: 'User',           optional: true, foreign_key: :created_by_id
  has_many   :children,   class_name: 'DirectoryEntry', foreign_key: :owner_id, dependent: :destroy
  has_many   :file_changes, dependent: :destroy

  validates :cur_name, presence: true
  validates :srcpath,  presence: true
  validates :ftype,    inclusion: { in: %w[file folder] }
  validates :srcpath,  uniqueness: { scope: :project_id }

  # -------------------------------------------------------------------------
  # Content replay
  # -------------------------------------------------------------------------

  # Replay all FileChange records in order and return the current file content.
  # Equivalent to calcCurrent() in the original CARBIDE.
  def calc_current
    doc = FsDocument.new
    file_changes.order(:revision, :id).each do |change|
      snake = camel_to_snake(change.change_type)

      if respond_to?("cmd_#{snake}", true)
        send("cmd_#{snake}", doc, change)
      else
        if doc.respond_to?("do_#{snake}")
          parsed = parse_change_data(change.change_data)
          doc.send("do_#{snake}", nil, parsed)
        end
      end
    end
    doc.get_contents
  end

  # -------------------------------------------------------------------------
  # Filesystem query helpers
  # -------------------------------------------------------------------------

  # Returns tree hash suitable for JSON serialisation.
  # { id, name, path, type, children: [...] }
  def self.tree_for_project(project_id)
    entries  = where(project_id: project_id).to_a
    root     = entries.find { |e| e.srcpath == '/' && e.ftype == 'folder' }
    return [] unless root

    by_owner = entries.group_by(&:owner_id)
    build_tree_node(root, by_owner)
  end

  def self.find_by_project_and_path(project_id, srcpath)
    find_by(project_id: project_id, srcpath: srcpath)
  end

  # -------------------------------------------------------------------------
  # Filesystem mutation helpers
  # -------------------------------------------------------------------------

  # Ensure the root folder for a project exists, creating it if needed.
  def self.ensure_root!(project_id)
    find_or_create_by!(project_id: project_id, srcpath: '/', ftype: 'folder') do |e|
      e.cur_name = '/'
    end
  end

  # Create a file entry (and all intermediate directories if mkdirp: true).
  # Returns the new DirectoryEntry or raises.
  def self.create_file!(project_id:, srcpath:, user_id: nil, data: nil, mkdirp: false)
    srcpath = normalize(srcpath)
    raise ArgumentError, "srcpath must start with /" unless srcpath.start_with?('/')

    # Ensure parent directory exists
    parent_path = File.dirname(srcpath)
    parent = find_by_project_and_path(project_id, parent_path)
    if parent.nil?
      raise "Parent directory #{parent_path} does not exist" unless mkdirp
      mkdir_p!(project_id: project_id, srcpath: parent_path, user_id: user_id)
      parent = find_by_project_and_path(project_id, parent_path)
    end

    existing = find_by_project_and_path(project_id, srcpath)
    return existing if existing

    entry = create!(
      project_id:    project_id,
      owner_id:      parent.id,
      created_by_id: user_id,
      cur_name:      File.basename(srcpath),
      srcpath:       srcpath,
      ftype:         'file'
    )

    if data && !data.empty?
      # Treat incoming bytes as UTF-8 and only scrub sequences that are
      # actually invalid. Calling .encode('UTF-8', replace: '') on an
      # ASCII-8BIT string strips every byte >= 0x80 — i.e. every multi-byte
      # UTF-8 char (en-dashes, em-dashes, smart quotes, accents). See the
      # matching fix in app/services/fs_loader.rb.
      data = data.dup.force_encoding('UTF-8')
      data = data.scrub('') unless data.valid_encoding?
      FileChange.create!(
        directory_entry_id: entry.id,
        user_id:            user_id || 1,
        change_type:        'setContents',
        change_data:        data,
        start_line:         0,
        start_char:         0,
        revision:           0
      )
    end

    entry
  end

  # Recursively create directories (mkdir -p).
  def self.mkdir_p!(project_id:, srcpath:, user_id: nil)
    srcpath = normalize(srcpath)
    return find_by_project_and_path(project_id, srcpath) if find_by_project_and_path(project_id, srcpath)

    # Walk from root down, creating any missing segment
    parts = srcpath.split('/').reject(&:empty?)
    current_path = ''
    parent = ensure_root!(project_id)

    parts.each do |part|
      current_path = "#{current_path}/#{part}"
      existing = find_by_project_and_path(project_id, current_path)
      if existing
        parent = existing
      else
        parent = create!(
          project_id:    project_id,
          owner_id:      parent.id,
          created_by_id: user_id,
          cur_name:      part,
          srcpath:       current_path,
          ftype:         'folder'
        )
      end
    end

    parent
  end

  # Rename this entry (files only for now; directory rename requires child srcpath rewrite).
  def rename!(new_name)
    raise "Directory rename not supported" if ftype == 'folder'
    parent_path  = File.dirname(srcpath)
    new_srcpath  = "#{parent_path}/#{new_name}".gsub('//', '/')
    update!(cur_name: new_name, srcpath: new_srcpath)
  end

  # -------------------------------------------------------------------------
  private
  # -------------------------------------------------------------------------

  # cmd_set_contents — replaces document content entirely.
  # Called by calc_current when change_type == 'setContents'.
  def cmd_set_contents(doc, change)
    data = change.change_data.to_s
    if data.include?("\n")
      doc.set_contents(data.split("\n", -1))
    else
      doc.set_contents([data])
    end
  end

  def self.build_tree_node(entry, by_owner)
    node = {
      id:      entry.id,
      name:    entry.cur_name,
      path:    entry.srcpath,
      type:    entry.ftype
    }
    if entry.ftype == 'folder'
      node[:children] = (by_owner[entry.id] || [])
        .sort_by { |e| [e.ftype == 'folder' ? 0 : 1, e.cur_name.downcase] }
        .map { |child| build_tree_node(child, by_owner) }
    end
    node
  end

  def camel_to_snake(str)
    str.gsub(/([A-Z])/) { "_#{$1.downcase}" }.sub(/^_/, '')
  end

  def parse_change_data(data)
    JSON.parse(data.to_s)
  rescue JSON::ParserError
    data
  end

  def self.normalize(path)
    path = path.to_s.strip
    path = "/#{path}" unless path.start_with?('/')
    path.chomp('/')
    path == '' ? '/' : path
  end
end
