# frozen_string_literal: true
module DbfsV2
  # DocumentCache — in-memory live buffer per (file_node, branch), hydrated once
  # from the revision log and advanced by each write. Reads are O(1); writes
  # stay coherent because every write path advances the cached buffer with the
  # same delta it just persisted. A head-id mismatch (merge, fast-forward,
  # external edit, cross-branch pointer move) makes the next read re-hydrate:
  # the cache is an accelerator, never a source of truth.
  #
  # Also tracks `revs_since_kf` / `bytes_since_kf` so Store can write keyframes
  # on a policy (every N revisions / M bytes ADDED) without re-replaying
  # history. The byte counter is a delta since the last keyframe, NOT the total
  # buffer size — otherwise every keystroke on a file larger than the threshold
  # would write a full-content keyframe.
  module DocumentCache
    Entry = Struct.new(:buffer, :head_id, :revs_since_kf, :bytes_at_kf) do
      def bytes = buffer.to_s.bytesize
      def bytes_since_kf = bytes - bytes_at_kf
    end

    @entries = {}
    @lock = Mutex.new

    class << self
      def key(node_id, branch) = "#{node_id}\u0000#{branch}"

      def get(node_id, branch)
        @lock.synchronize { @entries[key(node_id, branch)] }
      end

      def put(node_id, branch, buffer, head_id, revs_since_kf)
        @lock.synchronize do
          @entries[key(node_id, branch)] = Entry.new(buffer, head_id, revs_since_kf, buffer.to_s.bytesize)
        end
      end

      # Apply one already-persisted delta to the cached buffer and bump the head
      # + keyframe counter. No-op if this (node, branch) was never read (there is
      # no entry to advance). If the cached head is NOT the revision's parent,
      # the cache is stale (a write landed from another process) — invalidate it
      # rather than apply the delta on top of the wrong content. Returns the
      # entry so the caller can check the keyframe policy, or nil.
      def advance(node_id, branch, head_id, parent_id, delta)
        @lock.synchronize do
          k = key(node_id, branch)
          e = @entries[k]
          return nil unless e
          # Compare the cached head to this revision's parent UNCONDITIONALLY.
          # A nil cached head (empty base) only matches a nil parent (our own
          # first append). If a foreign write moved the head in between, parent
          # is a real id and nil != parent invalidates the stale entry —
          # otherwise we would advance an empty buffer and lose that content.
          if e.head_id != parent_id
            @entries.delete(k)
            return nil
          end
          e.buffer.apply(delta)
          e.head_id = head_id
          e.revs_since_kf += 1
          e
        end
      end

      def reset_keyframe_counter(node_id, branch)
        @lock.synchronize do
          e = @entries[key(node_id, branch)]
          next unless e
          e.revs_since_kf = 0
          e.bytes_at_kf = e.bytes
        end
      end

      # Drop one (node, branch) entry, e.g. when a merge/fast-forward moves the
      # head pointer without going through the write path.
      def invalidate(node_id, branch)
        @lock.synchronize { @entries.delete(key(node_id, branch)) }
      end

      # Drop every cached buffer for a file node (rename/delete safety).
      def invalidate_node(node_id)
        @lock.synchronize { @entries.delete_if { |k, _| k.start_with?("#{node_id}\u0000") } }
      end
    end
  end
end
