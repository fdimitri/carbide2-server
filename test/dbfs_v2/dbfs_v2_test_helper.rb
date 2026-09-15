# frozen_string_literal: true
# Shared helper for the DBFS v2 suite (ported from the carbide2-experimental
# prototype). Runs inside the Rails test environment, i.e. against Postgres —
# which is also what makes branch_lock_test assert a real SELECT ... FOR UPDATE.
#
# These are plain Minitest::Test classes, not ActiveSupport::TestCase: no
# fixtures, no transactional wrapping, no parallel workers. Every store lives
# in its own freshly created Project, so tests don't see each other's rows.
require_relative '../test_helper'

DBFS_V2_LIB = Rails.root.join('lib').to_s unless defined?(DBFS_V2_LIB)

module DbfsV2TestHelpers
  # A real Project row (file_nodes.project_id is a foreign key).
  def new_project_id
    Project.create!(name: "dbfs-v2-test-#{SecureRandom.hex(4)}", uuid: SecureRandom.uuid).id
  end

  def setup_store
    DbfsV2::Store.new(new_project_id)
  end
end

# Helpers for exercising the store across process boundaries (simulated foreign
# writers) and for reading content straight from the log.
module StoreTestHelpers
  include DbfsV2TestHelpers

  def d(t, p) = DbfsV2::Delta.new(t, p)
  def head(s, path, b = 'main') = s.find(path).branches.find_by!(name: b).head_revision_id

  # Simulates a write from ANOTHER worker process: persists a revision and moves
  # the head, but never touches this process's DocumentCache.
  def foreign_write(node, delta)
    b = node.branches.find_by!(name: 'main')
    r = Revision.create!(file_node_id: node.id, parent_id: b.head_revision_id, branch_id: b.id,
                         change_type: delta.type, change_data: delta.payload.to_json,
                         priority: 'foreign', timestamp: Time.now.utc)
    b.update!(head_revision_id: r.id)
    r
  end

  # Content by pure replay from genesis, ignoring keyframes and the cache.
  def replay_truth(node, rev_id)
    revs = DbfsV2::Chain.revision_index(node)
    buf = DbfsV2::Buffer.new('')
    DbfsV2::Chain.ancestor_ids(rev_id, revs).each do |rid|
      buf.apply(DbfsV2::Delta.parse(revs[rid].change_type, revs[rid].change_data))
    end
    buf.to_s
  end
end
