# frozen_string_literal: true
module DbfsV2
  # Merge — fast-forward, auto-merge, and user-resolved merge mechanics.
  #
  # Fast-forward: if `target`'s head is an ancestor of `source`'s head, just
  # move the target branch pointer forward (no new revision).
  #
  # Auto-merge: a real three-way merge at the DAG merge base (see
  # #auto_merge_content); overlapping writes are surfaced as a conflict.
  #
  # User-resolved: create a merge revision whose first parent is target's head
  # and second parent is source's head, with change_type setContents carrying
  # the resolved full content. The DAG records the convergence point; the OT
  # layer (or a human) supplies the merged bytes.
  module Merge
    module_function

    def fast_forward?(file_node, target_head_id, source_head_id)
      return true if target_head_id.nil? || target_head_id == source_head_id
      ancestors(file_node, source_head_id).include?(target_head_id)
    end

    def fast_forward!(file_node, target_name:, source_name:, user_id: nil)
      target = file_node.branches.find_by!(name: target_name)
      source = file_node.branches.find_by!(name: source_name)
      return { merged: false, reason: 'source has no head' } unless source.head_revision_id
      return { merged: false, reason: 'already at source head' } if target.head_revision_id == source.head_revision_id

      unless fast_forward?(file_node, target.head_revision_id, source.head_revision_id)
        return { merged: false, reason: 'not a fast-forward; resolve manually' }
      end

      # Serialize on the target branch row, and RE-CHECK under the lock: a write
      # landing between the check above and the lock would otherwise be orphaned
      # by moving the head past it.
      aborted = false
      ActiveRecord::Base.transaction do
        locked = Branch.lock.find(target.id)
        if fast_forward?(file_node, locked.head_revision_id, source.head_revision_id)
          locked.update!(head_revision_id: source.head_revision_id)
        else
          aborted = true
        end
      end
      return { merged: false, reason: 'target advanced concurrently; re-check' } if aborted

      DocumentCache.invalidate(file_node.id, target_name)
      { merged: true, head: source.head_revision_id }
    end

    def merge_commit!(file_node, target_name:, source_name:, resolved_content:, user_id: nil, expected_target_head: nil)
      target = file_node.branches.find_by!(name: target_name)
      source = file_node.branches.find_by!(name: source_name)
      raise 'source has no head' unless source.head_revision_id
      raise 'target has no head' unless target.head_revision_id

      # The target head the resolved bytes were produced against: the caller's
      # pinned revision, or the head we read now. If a write lands on the target
      # between this read and the lock, `locked.head_revision_id` differs —
      # recording a merge whose first parent is the new head would silently
      # discard that write (and the human resolved against stale content).
      # Refuse instead, so the caller re-resolves against the new head.
      expected = expected_target_head || target.head_revision_id

      # Lock the target branch row: the head read + revision insert + head
      # update must be atomic, or two concurrent merges/writes fork the head.
      rev = ActiveRecord::Base.transaction do
        locked = Branch.lock.find(target.id)
        if locked.head_revision_id != expected
          raise ConflictError,
                "target branch '#{target_name}' advanced while resolving; re-resolve"
        end
        r = Revision.create!(
          file_node_id: file_node.id,
          parent_id: locked.head_revision_id,
          second_parent_id: source.head_revision_id,
          branch_id: locked.id,
          change_type: 'setContents',
          change_data: { data: resolved_content }.to_json,
          user_id: user_id,
          timestamp: Time.now.utc
        )
        locked.update!(head_revision_id: r.id)
        r
      end
      DocumentCache.invalidate(file_node.id, target_name)
      rev
    end

    # All ancestor revision ids of `rev` (inclusive), following the FULL DAG
    # (both parents). Ancestry *membership* questions (fast-forward?, merge
    # base) must see a merge commit's second parent, or a branch already merged
    # in looks unmerged.
    def ancestors(file_node, rev_id)
      Chain.reachable_ids(rev_id, Chain.revision_index(file_node))
    end

    # Merge base of two revisions over the FULL DAG: a common ancestor that is
    # not itself an ancestor of any other common ancestor (i.e. the deepest
    # shared point). This sees a merge commit's second parent, so re-merging an
    # already-merged branch finds the previous source head rather than genesis.
    def lowest_common_ancestor(file_node, a_id, b_id)
      return a_id if a_id == b_id
      revs = Chain.revision_index(file_node)
      b_reach = Chain.reachable_ids(b_id, revs).to_set
      common = Chain.reachable_ids(a_id, revs).select { |r| b_reach.include?(r) }
      return nil if common.empty?

      common_set = common.to_set
      # A merge base is a common node that is NOT an ancestor of any OTHER
      # common node (reachable(n) includes n, so skip self).
      common.find do |c|
        common_set.none? { |c2| c2 != c && Chain.reachable_ids(c2, revs).include?(c) }
      end
    end

    # Conflict detection and the auto-merge content computation share ONE
    # definition of "conflict": diff each side against the DAG merge base
    # (setContents included, as a diff) and ask Transform#ambiguous? whether any
    # write regions overlap. The previous version walked each branch's revision
    # LIST and treated a setContents as rewriting the whole file, so it disagreed
    # with auto_merge_content (spurious conflicts on disjoint setContents edits;
    # and it missed insert-inside-replace).
    # Returns [] if clean, else [{ target:, source: }] with the regions involved.
    def conflicts(file_node, target_head_id, source_head_id)
      base_id = lowest_common_ancestor(file_node, target_head_id, source_head_id)
      base = base_id ? Content.at(file_node, base_id) : ''
      ours   = Transform.diff_prims(base, Content.at(file_node, target_head_id), 'ours')
      theirs = Transform.diff_prims(base, Content.at(file_node, source_head_id), 'theirs')
      return [] unless Transform.ambiguous?(ours, theirs)

      [{ target: regions_of(ours), source: regions_of(theirs) }]
    end

    def regions_of(prims)
      prims.map do |p|
        { start: p.start, end: p.finish,
          type: p.insert? ? 'insert' : (p.replace? ? 'replace' : 'delete') }
      end
    end

    def merge_conflicts?(file_node, target_name:, source_name:)
      target = file_node.branches.find_by!(name: target_name)
      source = file_node.branches.find_by!(name: source_name)
      return [] unless target.head_revision_id && source.head_revision_id
      conflicts(file_node, target.head_revision_id, source.head_revision_id)
    end

    # Auto-merge: diff each side against the DAG base and combine. Returns:
    #   { merged: true, content:, rev: }            on success
    #   { merged: true, fast_forward: true, head: } on fast-forward
    #   { merged: false, reason:, conflicts: }      on conflict / unmergeable
    def merge_auto(file_node, target_name:, source_name:, user_id: nil)
      target = file_node.branches.find_by!(name: target_name)
      source = file_node.branches.find_by!(name: source_name)
      return { merged: false, reason: 'source has no head' } unless source.head_revision_id
      return { merged: false, reason: 'target has no head' } unless target.head_revision_id
      return { merged: false, reason: 'already at source head' } if target.head_revision_id == source.head_revision_id
      # Binary content is opaque bytes; there is no text merge to attempt.
      return { merged: false, reason: 'binary node' } if file_node.binary?

      if fast_forward?(file_node, target.head_revision_id, source.head_revision_id)
        # Same locked pointer move as fast_forward!, re-checking under the lock
        # so a concurrent write can't be orphaned by the auto-FF.
        aborted = false
        ActiveRecord::Base.transaction do
          locked = Branch.lock.find(target.id)
          if fast_forward?(file_node, locked.head_revision_id, source.head_revision_id)
            locked.update!(head_revision_id: source.head_revision_id)
          else
            aborted = true
          end
        end
        return { merged: false, reason: 'target advanced concurrently; re-check' } if aborted

        DocumentCache.invalidate(file_node.id, target_name)
        return { merged: true, fast_forward: true, head: source.head_revision_id }
      end

      # Shared, diff-based conflict gate — the SAME check auto_merge_content
      # makes, so merge_conflicts? and merge_auto cannot disagree.
      confs = conflicts(file_node, target.head_revision_id, source.head_revision_id)
      return { merged: false, reason: 'conflict', conflicts: confs } unless confs.empty?

      # An opaque op (pcre) that cannot be auto-combined surfaces as a
      # ConflictError. ONLY that is reported as a conflict: any other error is a
      # bug and must propagate rather than masquerade as an unresolvable merge.
      begin
        content = auto_merge_content(file_node, target.head_revision_id, source.head_revision_id)
      rescue ConflictError => e
        return { merged: false, reason: 'conflict', error: e.message }
      end

      # Lock the target branch row: head read + insert + head update atomic.
      # `content` was computed against `target.head_revision_id`; if a write
      # landed on the target since, committing this merge would clobber it. So
      # re-check the head under the lock and abort instead — the caller re-runs
      # against the new head. (Mirrors the re-check in fast_forward!.)
      aborted = false
      rev = ActiveRecord::Base.transaction do
        locked = Branch.lock.find(target.id)
        if locked.head_revision_id != target.head_revision_id
          aborted = true
          nil
        else
          r = Revision.create!(
            file_node_id: file_node.id,
            parent_id: locked.head_revision_id,
            second_parent_id: source.head_revision_id,
            branch_id: locked.id,
            change_type: 'setContents',
            change_data: { data: content }.to_json,
            user_id: user_id,
            timestamp: Time.now.utc
          )
          locked.update!(head_revision_id: r.id)
          r
        end
      end
      return { merged: false, reason: 'target advanced concurrently; re-check' } if aborted

      DocumentCache.invalidate(file_node.id, target_name)
      { merged: true, content: content, rev: rev }
    end

    # Merged content, using a real three-way merge at the DAG base: diff the
    # base against each head into prims (same base coordinate space), then
    # OT-transform source's prims past target's and apply both. This handles
    # "merge a branch twice": the base is the previous source head, so its
    # already-merged edits are not present in either diff and are not replayed.
    def auto_merge_content(file_node, target_head_id, source_head_id)
      base_id = lowest_common_ancestor(file_node, target_head_id, source_head_id)
      base_content   = base_id ? Content.at(file_node, base_id) : ''
      ours_content   = Content.at(file_node, target_head_id)
      theirs_content = Content.at(file_node, source_head_id)

      ours_prims   = Transform.diff_prims(base_content, ours_content, 'ours')
      theirs_prims = Transform.diff_prims(base_content, theirs_content, 'theirs')

      # Overlapping write regions cannot be auto-merged; surface a conflict.
      raise ConflictError, 'overlapping changes' if Transform.ambiguous?(ours_prims, theirs_prims)

      theirs_prime = Transform.transform_list(theirs_prims, ours_prims)

      buf = Buffer.new(base_content)
      apply_prims(buf, ours_prims)     # ours, in base coords
      apply_prims(buf, theirs_prime)   # theirs', in base+ours coords
      buf.to_s
    end

    # Apply a list of atomic prims that are all in a SHARED coordinate space to
    # buf. Applying sequentially would let earlier edits shift later ones'
    # coordinates, so we apply right-to-left (descending start offset) so each
    # prim's coordinate stays valid. Ties (equal start) keep list order.
    def apply_prims(buf, prims)
      prims.sort_by { |p| -p.start }.each do |p|
        d = Transform.to_delta(p, buf)
        Delta.new(d[:type], d.reject { |k, _| k == :type }).apply_to(buf)
      end
    end
  end
end
