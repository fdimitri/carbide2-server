# frozen_string_literal: true
module DbfsV2
  # Content — reconstruct the full file content at any revision by replaying the
  # DAG forward. A keyframe (if one exists on the ancestor path) is used as the
  # starting buffer so we don't replay the entire history; keyframes never
  # replace the revision log, they only accelerate replay.
  module Content
    module_function

    def at(file_node, revision_id)
      revs = Chain.revision_index(file_node)
      rev = revs[revision_id]
      raise ActiveRecord::RecordNotFound, "Couldn't find Revision with 'id'=#{revision_id}" unless rev
      # Content type is PER-REVISION, not per-node: a text revision on a node
      # later promoted to binary must still replay as text (and vice versa).
      return blob_content(rev) if rev.change_type == 'writeBinary'
      path = Chain.ancestor_ids(revision_id, revs)   # genesis..rev, inclusive, in order
      buffer, replay = split_keyframe(file_node, path)
      replay.each do |rid|
        r = revs[rid]
        buffer.apply(Delta.parse(r.change_type, r.change_data))
      end
      buffer.to_s
    end

    def head(file_node, branch_name = Branch::MAIN)
      branch = branch_of(file_node, branch_name)
      return (file_node.binary? ? ''.b : '') unless branch && branch.head_revision_id
      at(file_node, branch.head_revision_id)
    end

    # Cached variant of #head: serve from the in-memory DocumentCache when its
    # head matches, otherwise hydrate (replay) once and populate the cache.
    # Falls back to the node's first branch when the requested one is absent
    # (e.g. a file created only on a non-main branch).
    def head_cached(file_node, branch_name = Branch::MAIN)
      branch = branch_of(file_node, branch_name)
      return (file_node.binary? ? ''.b : '') unless branch

      head_id = branch.head_revision_id
      if head_id.nil?
        # No head yet (empty file) — seed an empty buffer so subsequent writes
        # can advance it and the keyframe policy has something to track.
        return ''.b if file_node.binary?
        DocumentCache.put(file_node.id, branch.name, Buffer.new(''), nil, 0)
        return ''
      end

      revs = Chain.revision_index(file_node)
      head_rev = revs[head_id]
      # Binary head -> content-addressed lookup (no text cache).
      return at(file_node, head_id) if head_rev && head_rev.change_type == 'writeBinary'

      entry = DocumentCache.get(file_node.id, branch.name)
      return entry.buffer.to_s if entry && entry.head_id == head_id

      buffer = Buffer.new(at(file_node, head_id))
      DocumentCache.put(file_node.id, branch.name, buffer, head_id, 0)
      buffer.to_s
    end

    # Resolve a branch by name, falling back to the node's first branch.
    def branch_of(file_node, branch_name)
      file_node.branches.find_by(name: branch_name) || file_node.branches.first
    end

    # Binary revisions are content-addressed: the payload carries the blob's
    # SHA-256 digest, so content is one indexed lookup (no replay). A dangling
    # digest is a data-integrity error, not an empty file.
    def blob_content(rev)
      digest = rev.payload['sha256']
      raise "revision #{rev.id} has no sha256" unless digest
      DbfsV2.blob_store.get(digest)
    rescue RuntimeError => e
      raise "missing blob for revision #{rev.id} (sha256=#{digest}): #{e.message}"
    end

    # Given the ancestor path, return [buffer, remaining_ids] where buffer is
    # seeded from the deepest keyframe on the path and remaining_ids are the
    # revisions that still must be replayed (after the keyframe, incl. rev).
    def split_keyframe(file_node, path)
      kfs = Chain.keyframe_index(file_node)
      deepest = path.reverse.find { |rid| kfs.key?(rid) }
      return [Buffer.new(''), path] unless deepest

      idx = path.index(deepest)
      [Buffer.new(kfs[deepest].content), path[(idx + 1)..] || []]
    end
  end
end
