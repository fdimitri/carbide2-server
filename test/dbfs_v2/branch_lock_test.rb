# frozen_string_literal: true
#
# Content-head serialization.
#
# Every write and per-file merge takes `Branch.lock_head!(id)`: FOR SHARE on
# the project branch (the same row path ops / snapshots / forks / merges lock
# FOR UPDATE) then FOR UPDATE on the per-file line. On Postgres those clauses
# are real. On SQLite the Arel visitor DROPS them.
#
# So: assert both clauses where we can (Postgres), and skip-with-reason on
# SQLite rather than let a green suite imply the lock was tested. See
# decisions #21.
require_relative 'dbfs_v2_test_helper'

class BranchLockTest < Minitest::Test
  include StoreTestHelpers

  def postgres?
    ActiveRecord::Base.connection.adapter_name =~ /postg/i
  end

  def test_branch_lock_emits_for_update_on_postgres
    sql = Branch.lock.where(id: 'x').to_sql
    share = ProjectBranch.lock('FOR SHARE').where(id: 'x').to_sql
    if postgres?
      assert_match(/FOR UPDATE/i, sql, "Branch.lock must emit FOR UPDATE on Postgres")
      assert_match(/FOR SHARE/i, share, "ProjectBranch FOR SHARE must emit on Postgres")
    else
      skip "adapter=#{ActiveRecord::Base.connection.adapter_name}: Arel drops FOR UPDATE, " \
           "so Branch.lock is a NO-OP and the concurrent-head tests only prove the hooked path. " \
           "Run the suite on Postgres to enforce this. (decisions #21)"
    end
  end

  # The write path must actually take both locks — a structural guard so a
  # refactor that drops `.lock_head!` or moves SHARE onto the per-file line
  # fails here.
  def test_write_and_merge_paths_take_the_project_branch_share_lock
    src = File.read(File.join(DBFS_V2_LIB, 'dbfs_v2/store.rb'))
    assert_includes src, 'Branch.lock_head!',
                    'Store#write must serialize on Branch.lock_head!'
    merge = File.read(File.join(DBFS_V2_LIB, 'dbfs_v2/merge.rb'))
    assert_includes merge, 'Branch.lock_head!',
                    'Merge must serialize on Branch.lock_head!'
    model = File.read(File.expand_path('../app/models/branch.rb', DBFS_V2_LIB))
    assert_includes model, 'FOR SHARE',
                    'lock_head! takes FOR SHARE on the project branch row'
    assert_includes model, 'ProjectBranch.lock("FOR SHARE")',
                    'SHARE is on ProjectBranch, not the per-file line'
    assert_includes model, 'ProjectBranch.live.where(project_id: pid).lock("FOR SHARE")',
                    'a detached per-file line still SHARE-locks the project branches'
    assert_match(/nb\.project_branch_id\s+=\s+project_branch_id/, src,
                 'branch_at stamps project_branch_id so the line is in the lock set')
    assert_includes src, 'row.update_columns(project_branch_id: project_branch_id)',
                    'a leftover detached line is stamped, not left out of the lock set'
    refute File.exist?(File.expand_path('../app/models/branch_entry.rb', DBFS_V2_LIB)),
           'branch_entries is not a live index; the model is gone'
  end
end
