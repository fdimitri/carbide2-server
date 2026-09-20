# frozen_string_literal: true
require 'digest'

module DbfsV2
  # ProjectDag — stored project-level DAG. A node is an immutable
  # (path → identity → content binding). Running nodes point at a live
  # content line (submodule→branch). Snapshots freeze identity-revs and
  # hang off the running head; HEAD does not move onto a snapshot.
  # A project branch tip is a pointer at the latest running node.
  module ProjectDag
    module_function

    def advance!(branch, add: [], remove_ids: [], rewrite: {}, second_parent: nil,
                 parent: nil, inherit: true, user_id: nil)
      parent ||= branch.head_node
      rows = (inherit && parent) ? parent.entry_rows : []
      by_id = rows.to_h { |r| [r[:file_node_id], r] }
      Array(remove_ids).each { |id| by_id.delete(id) }
      rewrite.each do |id, attrs|
        next unless by_id[id]
        by_id[id] = by_id[id].merge(attrs.transform_keys(&:to_sym))
      end
      Array(add).each do |r|
        h = r.transform_keys(&:to_sym)
        by_id[h[:file_node_id]] = { revision_id: nil }.merge(h)
      end
      rows = by_id.values.sort_by { |r| r[:path].to_s }
      if second_parent.nil? && parent && same_entries?(parent.entry_rows, rows)
        return parent
      end
      insert!(branch, parent: parent, second_parent: second_parent, kind: ProjectNode::RUNNING,
              entries: rows, user_id: user_id)
    end

    def snapshot!(branch, name: nil, user_id: nil)
      head = branch.head_node
      raise ArgumentError, 'nothing to snapshot' unless head
      if name && ProjectNode.snapshots.where(project_id: branch.project_id, name: name).exists?
        dummy = ProjectNode.new(project_id: branch.project_id, kind: ProjectNode::SNAPSHOT, name: name)
        dummy.errors.add(:name, :taken)
        raise ActiveRecord::RecordInvalid, dummy
      end
      rows = frozen_rows(head)
      insert!(branch, parent: head, kind: ProjectNode::SNAPSHOT, name: name, entries: rows, user_id: user_id)
    end

    # Unnamed snapshot of the running head. Used as a fork/merge-base cut so
    # later writes on those content lines cannot move the recorded tree.
    def freeze!(branch, user_id: nil)
      return nil unless branch.head_node
      snapshot!(branch, name: nil, user_id: user_id)
    end

    def frozen_rows(head)
      rows = head.entry_rows
      cb_ids = rows.filter_map { |r| r[:content_branch_id] }
      heads = Branch.where(id: cb_ids).pluck(:id, :head_revision_id).to_h
      rows.map do |r|
        rev = r[:revision_id] || heads[r[:content_branch_id]]
        r.merge(revision_id: rev)
      end
    end

    def insert!(branch, parent:, entries:, kind:, second_parent: nil, name: nil, user_id: nil)
      id = tree_hash(parent_id: parent&.id, second_parent_id: second_parent&.id, kind: kind, name: name, entries: entries)
      now = Time.now.utc
      node = ProjectNode.create!(
        id: id, project_id: branch.project_id, project_branch_id: branch.id,
        parent_id: parent&.id, second_parent_id: second_parent&.id,
        kind: kind, name: name, user_id: user_id, created_at: now, updated_at: now
      )
      if entries.any?
        ProjectNodeEntry.insert_all!(entries.map { |r|
          { project_node_id: id, file_node_id: r[:file_node_id], path: r[:path], ftype: r[:ftype] || 'file',
            content_branch_id: r[:content_branch_id], revision_id: r[:revision_id],
            created_at: now, updated_at: now }
        })
      end
      point_head!(branch, node) if kind == ProjectNode::RUNNING
      node
    rescue ActiveRecord::RecordNotUnique
      existing = ProjectNode.find_by(id: id)
      raise unless existing
      point_head!(branch, existing) if kind == ProjectNode::RUNNING
      existing
    end

    def tree_hash(parent_id:, second_parent_id:, kind:, name:, entries:)
      buf = +"#{kind}\0#{parent_id}\0#{second_parent_id}\0#{name}\n"
      entries.sort_by { |r| r[:path].to_s }.each do |r|
        buf << "#{r[:path]}\t#{r[:file_node_id]}\t#{r[:ftype] || 'file'}\t#{r[:content_branch_id]}\t#{r[:revision_id]}\n"
      end
      Digest::SHA256.hexdigest(buf)
    end

    # HEAD of `branch` (or a specific node) as a ProjectState view: paths and
    # the live (or frozen) identity-rev of each file.
    def view(branch, node: nil)
      n = node || branch.head_node
      entries = {}
      if n
        cbs = Branch.where(id: n.entries.where.not(content_branch_id: nil).select(:content_branch_id)).index_by(&:id)
        n.entries.each do |e|
          cb = cbs[e.content_branch_id]
          rev = n.snapshot? ? e.revision_id : (cb&.head_revision_id || e.revision_id)
          entries[e.file_node_id] = ProjectState::Entry.new(
            file_node_id: e.file_node_id, path: e.path, ftype: e.ftype,
            branch: cb&.name, revision_id: rev
          )
        end
      end
      ProjectState.new(project_id: branch.project_id, seq: Clock.now(branch.project_id),
                       branch_set: BranchSet.new(branch.name), entries: entries)
    end

    def same_entries?(a, b)
      norm = lambda do |rows|
        rows.map { |r|
          [r[:file_node_id], r[:path].to_s, (r[:ftype] || 'file').to_s,
           r[:content_branch_id].to_s, r[:revision_id].to_s]
        }.sort
      end
      norm.call(a) == norm.call(b)
    end

    def point_head!(branch, node)
      now = Time.now.utc
      branch.update_columns(head_node_id: node.id, updated_at: now)
      if branch.association(:head_node).loaded?
        branch.association(:head_node).reset
      end
      branch.head_node_id = node.id
    end
  end
end
