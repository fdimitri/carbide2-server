# frozen_string_literal: true
module DbfsV2
  # Chain — preloaded ancestry walking.
  #
  # Walking a file's revisions by following `parent_id` one AR load at a time is
  # O(N) queries (the classic N+1). These helpers load the whole set in a single
  # query and walk parent pointers in memory. Used by Content#at, Merge#ancestors,
  # Store#revisions_between and Store#new_since.
  module Chain
    module_function

    # All revisions for a node, one query, keyed by id. Reloaded so that a
    # revision written by another connection/process after this node object was
    # built is still seen (the association may be cached from an earlier read).
    def revision_index(file_node)
      file_node.revisions.reload.index_by(&:id)
    end

    # All keyframes for a node, one query, keyed by revision_id.
    def keyframe_index(file_node)
      file_node.keyframes.reload.index_by(&:revision_id)
    end

    # Ordered revision ids from genesis -> `rev_id` (inclusive), following the
    # first parent. This is the REPLAY order (merge commits are setContents
    # snapshots, so their content comes entirely from the first-parent line).
    # Returns [] if `rev_id` is unknown. `index` is a preloaded id => Revision hash.
    def ancestor_ids(rev_id, index)
      path = []
      seen = {}
      cur = rev_id
      while cur && index[cur] && !seen[cur]
        path.unshift(cur)
        seen[cur] = true
        cur = index[cur].parent_id
      end
      path
    end

    # Full-DAG ancestor SET (both parents, cycle-guarded). Use this for
    # ancestry *membership* / reachability questions (fast-forward?,
    # merge-base), where a merge commit's second parent must be visible.
    # For linear replay order use #ancestor_ids instead.
    def reachable_ids(rev_id, index)
      seen = {}
      stack = [rev_id]
      until stack.empty?
        cur = stack.pop
        next if cur.nil? || seen[cur] || !index[cur]
        seen[cur] = true
        r = index[cur]
        stack << r.parent_id
        stack << r.second_parent_id
      end
      seen.keys
    end
  end
end
