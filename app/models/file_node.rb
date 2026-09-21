# frozen_string_literal: true
class FileNode < ApplicationRecord
  self.primary_key = 'id'

  # `branches` is the live set — what every name lookup wants. Tombstoned
  # branches (ADR-042) stay reachable through `all_branches` for history
  # rendering, where a revision committed on a since-deleted branch still
  # needs its label.
  has_many :branches, -> { where(deleted_at: nil) }, dependent: :destroy
  has_many :all_branches, class_name: 'Branch', dependent: :destroy
  has_many :revisions, dependent: :destroy
  has_many :file_events, dependent: :destroy
  has_many :project_tree_entries, dependent: :delete_all
  has_many :keyframes, dependent: :destroy
  belongs_to :parent, class_name: 'FileNode', foreign_key: 'parent_id', optional: true
  has_many :children, class_name: 'FileNode', foreign_key: 'parent_id', dependent: :destroy

  before_validation :assign_id, on: :create
  before_validation :set_cur_name, on: :create
  before_validation :set_mtime, on: :create

  validates :path, presence: true
  validates :ftype, inclusion: { in: %w[file folder] }

  # Soft-delete of a *node row* is leftover from when file_nodes was a path
  # index. Live-ness is presence on a branch's running head; FileNode is identity.
  scope :live, -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }

  def deleted?
    deleted_at.present?
  end

  def symlink?
    symlink_target.present?
  end

  # Full stat snapshot for the explorer Properties panel and fs/stat.
  # `size` is computed dynamically for text files (replay the head) and read
  # from `last_size` for binary files; `revisions` is the per-file DAG size.
  def stat_hash
    {
      id:          id,
      path:        path,
      name:        cur_name || File.basename(path),
      type:        ftype,
      binary:      binary?,
      size:        content_size,
      revisions:   revisions.count,
      posix_mode:  posix_mode,
      posix_owner: owner,
      posix_group: posix_group,
      mtime:       mtime,
      created_at:  created_at,
      updated_at:  updated_at,
      created_by:  created_by,
      last_size:   last_size
    }
  end

  # Byte size of the current content. Binary -> last_size (set on write); text
  # -> bytes of the replayed head; folders -> 0. Symlinks report their resolved
  # target's size (writes/reads resolve through, so stat does too).
  def content_size
    target = resolve || self
    return 0 unless target.ftype == 'file'
    return target.last_size.to_i if target.binary?
    DbfsV2::Content.head_cached(target).bytesize
  end

  # Resolve a symlink chain to its final (non-symlink) FileNode. Bounded walk
  # (ADR-026): follows symlink_target (a normalized DBFS path) until a real
  # node is reached or the bound is exceeded. A tombstoned target is treated as
  # absent (the link dangles).
  def resolve(seen: [], depth: 0)
    return self unless symlink?
    return nil if depth >= 40 || seen.include?(id)

    target = begin
      main = ProjectBranch.live.find_by(project_id: project_id, name: Branch::MAIN)
      entry = main&.head_entries&.find_by(path: symlink_target)
      entry&.file_node
    end
    return nil unless target

    target.resolve(seen: seen + [id], depth: depth + 1)
  end

  def root?
    path == '/'
  end

  private

  def assign_id
    self.id ||= SecureRandom.uuid
  end

  def set_cur_name
    self.cur_name ||= (path == '/' ? '/' : File.basename(path))
  end

  def set_mtime
    self.mtime ||= Time.current
  end
end
