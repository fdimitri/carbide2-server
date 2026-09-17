# frozen_string_literal: true
module DbfsV2
  # Rebase — land a sequence of edits authored against an older revision onto
  # a branch head, as operational transforms, one edit at a time.
  #
  # Merge#auto_merge_content merges two *contents*: it diffs each side against
  # the base and has only a guess at what was edited. A rebase uses the edits
  # themselves: each authored edit is transformed past everything that landed on
  # the branch since the base, and what landed is transformed past the edit in
  # turn (so the next authored edit meets it in the right coordinates). Only
  # edits that really overlap are refused (Transform#ambiguous?, the same rule
  # as the live write path; a setContents on either side claims the lines its
  # diff rewrites, decisions #29). Merge#merge_auto replays a branch this way.
  #
  # The result is linear on the target: one revision per authored edit (OT may
  # split one). The last revision records the authored sequence's own head as
  # its second parent and stores the BRIDGE — the edits that take the author's
  # state (base + its edits) to the new head. The bridge is what lets the author
  # keep going from its own state: a later rebase based on that second parent
  # starts from the bridge instead of needing a first-parent path.
  #
  #   Rebase.onto!(store, node, deltas, base_id:, source_head_id:, user_id:)
  #   # => { revisions: [...], bridge: [delta hashes], head: id }
  #   # raises ConflictError (nothing committed) on an overlap
  #
  # Before committing, the bridge is checked: applying it to the author's state
  # must produce exactly the new head. A mismatch means the transforms did not
  # converge; it is refused as a conflict rather than committed.
  module Rebase
    module_function

    def onto!(store, node, deltas, base_id:, source_head_id:, user_id: nil, branch: Branch::MAIN)
      target = node.branches.find_by!(name: branch)

      ActiveRecord::Base.transaction do
        locked = Branch.lock.find(target.id)
        concurrent = concurrent_since(node, base_id, locked.head_revision_id)
        raise ConflictError, "base #{base_id} is not in #{node.path}'s history on #{branch}" if concurrent.nil?

        res = compute(Content.at(node, base_id), deltas, concurrent, label: node.path)
        out = res[:deltas]

        # Carrier for the second parent + bridge when every authored edit
        # transformed away (e.g. deleting text a concurrent edit already deleted).
        out << Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: '' }) if out.empty?

        revs = out.map do |d|
          store.write(node.path, d, base_revision_id: locked.reload.head_revision_id, branch: branch, user_id: user_id)
        end.flatten
        last = revs.last
        last.update_columns(second_parent_id: source_head_id, bridge: res[:bridge].to_json)
        { revisions: revs, bridge: res[:bridge], head: last.id }
      end
    end

    # The pure rebase, no storage: `deltas` (authored in order from
    # `base_content`) transformed past `concurrent` (landed in order from the
    # same base, priorities set). Returns
    #   { deltas: [Delta] to apply after concurrent,
    #     bridge: [delta hashes] to apply after the authored edits,
    #     content: the new head content, local: the author's state }
    # Raises OverlapConflict (with regions) on an overlap, ConflictError when
    # the result does not converge, ArgumentError for an out-of-range edit.
    def compute(base_content, deltas, concurrent, label: 'file')
      local = Buffer.new(base_content)
      cstate = Buffer.new(local.to_s)
      bridge = concurrent.map do |d|
        prims = Transform.to_prims(d, cstate)
        d.apply_to(cstate)
        prims
      end
      out = []

      deltas.each_with_index do |authored, i|
        authored = authored.is_a?(Delta) ? authored : Delta.parse(authored['type'] || authored[:type], authored)
        authored.validate_against!(local)
        authored.priority ||= authored.priority_for(nil)
        prims = Transform.to_prims(authored, local)
        bridge = bridge.map do |c|
          if Transform.ambiguous?(prims, c)
            raise OverlapConflict.new("edit #{i} overlaps a concurrent change on #{label}",
                                      regions: [{ target: Merge.regions_of(c), source: Merge.regions_of(prims) }])
          end
          moved = Transform.transform_list(prims, c)
          c2 = Transform.transform_list(c, prims)
          prims = moved
          c2
        end
        authored.apply_to(local)
        Transform.deltas_for(prims, cstate).each do |h|
          out << Delta.new(h[:type], h.reject { |k, _| k == :type }).tap { |d| d.priority = authored.priority }
        end
      end

      check = Buffer.new(local.to_s)
      bridge_deltas = bridge.flat_map { |c| Transform.deltas_for(c, check) }
      unless check.to_s == cstate.to_s
        raise ConflictError, "rebase of #{deltas.size} edit(s) on #{label} did not converge; refused"
      end

      { deltas: out, bridge: bridge_deltas, content: cstate.to_s, local: local.to_s }
    end

    # The edits from `base_id`'s content to `head_id`'s content, in order, as
    # Deltas with priorities set — or nil when there's no way to get there:
    #   * base on the head's first-parent chain: the revisions after it;
    #   * base is the second parent of a first-parent revision that carries a
    #     bridge (an earlier rebase's source head): that bridge, then the
    #     revisions after that revision.
    def concurrent_since(node, base_id, head_id)
      index = Chain.revision_index(node)
      chain = Chain.ancestor_ids(head_id, index)
      if (idx = chain.index(base_id))
        return chain[(idx + 1)..].map { |rid| revision_delta(index[rid]) }
      end

      idx = chain.rindex { |rid| index[rid].second_parent_id == base_id && index[rid].bridge.present? }
      return nil unless idx

      carrier = index[chain[idx]]
      bridged = JSON.parse(carrier.bridge).each_with_index.map do |h, i|
        Delta.new(h['type'], h.reject { |k, _| k == 'type' }).tap { |d| d.priority = "bridge:#{carrier.id}:#{i}" }
      end
      bridged + chain[(idx + 1)..].map { |rid| revision_delta(index[rid]) }
    end

    # The revisions after `base_id` on `head_id`'s first-parent chain, as
    # Deltas with priorities set; nil when base is not on that chain.
    def authored_since(node, base_id, head_id)
      index = Chain.revision_index(node)
      chain = Chain.ancestor_ids(head_id, index)
      idx = chain.index(base_id)
      return nil unless idx

      chain[(idx + 1)..].map { |rid| revision_delta(index[rid]) }
    end

    def revision_delta(rev)
      Delta.parse(rev.change_type, rev.change_data).tap { |d| d.priority = rev.priority || rev.id }
    end
  end
end
