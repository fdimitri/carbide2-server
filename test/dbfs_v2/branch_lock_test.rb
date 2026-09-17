# frozen_string_literal: true
#
# Branch-row serialization.
#
# Every write and merge serializes on `Branch.lock.find(id)` so the head read,
# revision insert and head update are atomic. On Postgres that emits
# `SELECT ... FOR UPDATE`. On SQLite the Arel visitor DROPS the lock clause, so
# the lock is a no-op there and the "target advanced concurrently" paths cannot
# be exercised for real.
#
# So: assert FOR UPDATE where we can (Postgres), and skip-with-reason on SQLite
# rather than let a green suite imply the lock was tested. See decisions #21.
require_relative 'dbfs_v2_test_helper'

class BranchLockTest < Minitest::Test
  include StoreTestHelpers

  def postgres?
    ActiveRecord::Base.connection.adapter_name =~ /postg/i
  end

  def test_branch_lock_emits_for_update_on_postgres
    sql = Branch.lock.where(id: 'x').to_sql
    if postgres?
      assert_match(/FOR UPDATE/i, sql, "Branch.lock must emit FOR UPDATE on Postgres")
    else
      # Documents reality: on this adapter the lock clause is dropped.
      skip "adapter=#{ActiveRecord::Base.connection.adapter_name}: Arel drops FOR UPDATE, " \
           "so Branch.lock is a NO-OP and the concurrent-head tests only prove the hooked path. " \
           "Run the suite on Postgres to enforce this. (decisions #21)"
    end
  end

  # The write path must actually take the lock (not just build a locked
  # relation) — a structural guard so a refactor that drops `.lock` fails here.
  def test_write_and_merge_paths_take_the_branch_lock
    src = File.read(File.join(DBFS_V2_LIB, 'dbfs_v2/store.rb'))
    assert_includes src, 'Branch.lock.find',
                    'Store#write must serialize on Branch.lock'
    merge = File.read(File.join(DBFS_V2_LIB, 'dbfs_v2/merge.rb'))
    assert_includes merge, 'Branch.lock.find',
                    'Merge must serialize on Branch.lock'
  end
end
