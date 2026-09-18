# frozen_string_literal: true
module DbfsV2
  # Merge — fast-forward, auto-merge, and user-resolved merge mechanics.
  #
  # Fast-forward: if `target`'s head is an ancestor of `source`'s head, just
  # move the target branch pointer forward (no new revision).
  #
  # Auto-merge: the source branch's edits since the DAG merge base are replayed
  # onto the target through Rebase (#replay_plan, #replay!). Without edit
  # history to replay, a three-way content merge at the merge base
  # (#auto_merge_content). Either way overlapping changes, and two changes to
  # the same line when one side is a whole-file snapshot, are a conflict.
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

    def merge_commit!(file_node, target_name:, source_name:, resolved_content:, user_id: nil,
                      expected_target_head: nil, expected_source_head: nil)
      target = file_node.branches.find_by!(name: target_name)
      source = file_node.branches.find_by!(name: source_name)
      raise 'source has no head' unless source.head_revision_id
      raise 'target has no head' unless target.head_revision_id
      # The human resolved against a particular source head too; if the source
      # moved since, the recorded second parent would claim edits the
      # resolution never saw. Refuse, so the caller re-previews.
      if expected_source_head && expected_source_head != source.head_revision_id
        raise ConflictError, "source branch '#{source_name}' advanced while resolving; re-resolve"
      end

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

    # Conflict detection and the auto-merge share ONE computation per path, so
    # merge_conflicts? and merge_auto cannot disagree:
    #   * replay (the normal case, see #replay_plan): the source branch's own
    #     edits are rebased past the target's, as the live write path does, and
    #     a conflict is what Rebase.compute refuses;
    #   * content (no edit history to replay): diff each side against the DAG
    #     merge base and ask Transform#ambiguous?.
    # Either way a snapshot diff claims the whole lines it changes, so two
    # changes to the same line conflict rather than garble (decisions #29).
    # Returns [] if clean, else [{ target:, source: }] with the regions involved.
    def conflicts(file_node, target_head_id, source_head_id)
      if (plan = replay_plan(file_node, target_head_id, source_head_id))
        begin
          Rebase.compute(plan[:base_content], plan[:authored], plan[:concurrent], label: file_node.path)
          return []
        rescue OverlapConflict => e
          return e.regions
        rescue ConflictError
          return [{ target: [], source: [] }]
        end
      end

      base_id = lowest_common_ancestor(file_node, target_head_id, source_head_id)
      base = base_id ? Content.at(file_node, base_id) : ''
      ours   = Transform.diff_prims(base, Content.at(file_node, target_head_id), 'ours')
      theirs = Transform.diff_prims(base, Content.at(file_node, source_head_id), 'theirs')
      return [] unless Transform.ambiguous?(ours, theirs)

      [{ target: regions_of(ours), source: regions_of(theirs) }]
    end

    # How to replay `source_head_id` onto `target_head_id`, or nil when there is
    # no edit history to replay (fall back to the content merge):
    #   { base_content:, authored: [Delta], concurrent: [Delta] }
    # authored: the source's first-parent revisions after the merge base.
    # concurrent: what the target has seen since the base (Rebase.concurrent_since:
    # its first-parent revisions, or an earlier replay's bridge and the
    # revisions after it, which is what makes merging a branch twice work).
    # Branches with no common ancestor (cut from a file with no revision yet)
    # replay their whole histories from empty.
    def replay_plan(file_node, target_head_id, source_head_id)
      base_id = lowest_common_ancestor(file_node, target_head_id, source_head_id)
      if base_id
        authored = Rebase.authored_since(file_node, base_id, source_head_id)
        concurrent = Rebase.concurrent_since(file_node, base_id, target_head_id)
        return nil unless authored && concurrent

        { base_content: Content.at(file_node, base_id), authored: authored, concurrent: concurrent }
      else
        authored = whole_history(file_node, source_head_id)
        concurrent = whole_history(file_node, target_head_id)
        return nil unless authored && concurrent

        { base_content: '', authored: authored, concurrent: concurrent }
      end
    end

    # Every revision from genesis to `head_id` on its first-parent chain, or nil
    # when the chain doesn't reach a genesis revision.
    def whole_history(file_node, head_id)
      index = Chain.revision_index(file_node)
      chain = Chain.ancestor_ids(head_id, index)
      return nil if chain.empty? || index[chain.first].parent_id

      chain.map { |rid| Rebase.revision_delta(index[rid]) }
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

    # Auto-merge. Returns:
    #   { merged: true, content:, rev:, replayed: true, revisions: } replayed
    #   { merged: true, content:, rev: }            content merge commit
    #   { merged: true, fast_forward: true, head: } on fast-forward
    #   { merged: false, reason:, conflicts: }      on conflict / unmergeable
    #
    # Replay (needs `store`, which Store#merge passes): the source's edits are
    # rebased onto the target one at a time and committed as linear revisions;
    # the last one records the source head as its second parent and stores the
    # bridge (see Rebase). Without history to replay, the merged content is
    # committed as one setContents merge commit.
    def merge_auto(file_node, target_name:, source_name:, user_id: nil, store: nil)
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

      if store && (plan = replay_plan(file_node, target.head_revision_id, source.head_revision_id))
        return replay!(store, file_node, target, source, plan, user_id: user_id)
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

    # Commit a replay plan made against `target.head_revision_id`. As with the
    # content merge, a write that landed on the target since the plan aborts
    # the merge rather than being skipped.
    def replay!(store, file_node, target, source, plan, user_id: nil)
      aborted = false
      result = nil
      begin
        ActiveRecord::Base.transaction do
          locked = Branch.lock.find(target.id)
          if locked.head_revision_id != target.head_revision_id
            aborted = true
            next
          end

          res = Rebase.compute(plan[:base_content], plan[:authored], plan[:concurrent], label: file_node.path)
          out = res[:deltas]
          # Carrier for the second parent + bridge when every source edit
          # transformed away (the target already made the same change).
          out << Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: '' }) if out.empty?
          revs = out.map do |d|
            store.write(file_node.path, d, base_revision_id: locked.reload.head_revision_id,
                                           branch: target.name, user_id: user_id)
          end.flatten
          last = revs.last
          last.update_columns(second_parent_id: source.head_revision_id, bridge: res[:bridge].to_json)
          result = { merged: true, replayed: true, content: res[:content], rev: last, revisions: revs }
        end
      rescue OverlapConflict => e
        return { merged: false, reason: 'conflict', conflicts: e.regions, error: e.message }
      rescue ConflictError => e
        return { merged: false, reason: 'conflict', conflicts: [{ target: [], source: [] }], error: e.message }
      end
      return { merged: false, reason: 'target advanced concurrently; re-check' } if aborted

      result
    end

    # Everything a human needs to resolve source into target: the three
    # contents and their revisions, the conflict regions the auto-merge
    # refused on, and a line-based diff3 with markers (Diff3) to start from.
    # `clean` means merge_auto would succeed; `merged` is then its exact
    # result, so a review-before-merge shows what will be committed.
    def preview(file_node, target_name:, source_name:)
      target = file_node.branches.find_by!(name: target_name)
      source = file_node.branches.find_by!(name: source_name)
      raise 'source has no head' unless source.head_revision_id
      t_head, s_head = target.head_revision_id, source.head_revision_id
      base_id = t_head ? lowest_common_ancestor(file_node, t_head, s_head) : nil
      base    = base_id ? Content.at(file_node, base_id) : ''
      ours    = t_head ? Content.at(file_node, t_head) : ''
      theirs  = Content.at(file_node, s_head)

      regions = t_head ? conflicts(file_node, t_head, s_head) : []
      auto    = nil
      if regions.empty? && t_head
        begin
          auto = auto_merge_content(file_node, t_head, s_head)
        rescue ConflictError
          auto = nil
        end
      elsif t_head.nil?
        auto = theirs
      end
      # Clean: what merge_auto will commit, no markers. Otherwise the diff3
      # text with markers and its blocks.
      d3 = auto ? { text: auto, conflicts: 0, blocks: [] } : Diff3.merge(base, ours, theirs, labels: [target_name, source_name])
      {
        target: target_name, source: source_name,
        base_revision: base_id, target_head: t_head, source_head: s_head,
        base: base, ours: ours, theirs: theirs,
        clean: !auto.nil?, conflicts: regions,
        merged: d3[:text], conflict_blocks: d3[:blocks].map(&:to_h), conflict_count: d3[:conflicts]
      }
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

      # Overlapping write regions (including two changes to one claimed line)
      # cannot be auto-merged; surface a conflict.
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
      # sort_by is not stable in Ruby; the index keeps equal-start prims in list
      # order (a replace's delete before its insert).
      prims.each_with_index.sort_by { |p, i| [-p.start, i] }.map(&:first).each do |p|
        d = Transform.to_delta(p, buf)
        Delta.new(d[:type], d.reject { |k, _| k == :type }).apply_to(buf)
      end
    end
  end
end
