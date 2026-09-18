# frozen_string_literal: true
module DbfsV2
  # ProjectMerge — merge one project branch set into another (ADR-042).
  #
  # Existence is project-wide today (a file exists or not regardless of
  # branch; only content is per-branch), so the file-set half of a project
  # merge is trivial and what remains is per-file: for every file where the
  # two sets resolve to different branches with different heads, merge source
  # into target — fast-forward where possible, three-way auto-merge otherwise
  # (Merge.merge_auto, with ADR-036's conflict gate).
  #
  # Atomic: all the per-file merges run in one transaction; any file that
  # conflicts, or whose head moves under its lock, rolls the whole merge back
  # and is reported in `unresolved`. Nothing is left half-merged.
  module ProjectMerge
    module_function

    # Returns
    #   { merged: true,  seq:, files: [{ path:, target:, source:, action: 'fast_forward' | 'auto' }], unresolved: [] }
    #   { merged: false, seq:, files: [...would have been...], unresolved: [{ path:, target:, source:, reason:, conflicts: }] }
    def merge(store, target_set:, source_set:, user_id: nil)
      target_set = BranchSet.wrap(target_set)
      source_set = BranchSet.wrap(source_set)
      raise ArgumentError, 'source and target branch sets are the same' if target_set == source_set

      now = store.seq
      t   = ProjectState.at(store, seq: now, branch_set: target_set)
      s   = ProjectState.at(store, seq: now, branch_set: source_set)

      work = s.files.filter_map do |e|
        te = t.entries[e.file_node_id]
        next if te.nil? || te.branch.nil? || e.branch.nil? || te.branch == e.branch
        next if te.revision_id == e.revision_id
        { path: e.path, target: te.branch, source: e.branch, source_head: e.revision_id }
      end

      files, unresolved = [], []
      ActiveRecord::Base.transaction do
        work.each do |w|
          res = store.merge(w[:path], target: w[:target], source: w[:source], auto: true, user_id: user_id)
          if res[:merged]
            head = store.find(w[:path]).branches.find_by!(name: w[:target]).head_revision_id
            files << w.slice(:path, :target, :source)
                      .merge(action: head == w[:source_head] ? 'fast_forward' : 'auto')
          elsif res[:reason] == 'already at source head'
            next
          else
            unresolved << w.slice(:path, :target, :source).merge(reason: res[:reason], conflicts: res[:conflicts] || [])
          end
        end
        raise ActiveRecord::Rollback if unresolved.any?
      end

      # Per-file merges invalidated their DocumentCache entries as they went;
      # after a rollback that is merely a dropped cache, never wrong content.
      { merged: unresolved.empty?, seq: now, files: files, unresolved: unresolved }
    end
  end
end
