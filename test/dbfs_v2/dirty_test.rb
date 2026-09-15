# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class DirtyTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_not_dirty_when_since_is_head
    @s.create_file('/f.txt', content: 'a')
    head = @s.branches('/f.txt').find { |b| b[:name] == 'main' }[:head]
    refute @s.dirty?('/f.txt', since: head)
  end

  def test_dirty_after_write
    @s.create_file('/f.txt', content: 'a')
    before = @s.branches('/f.txt').find { |b| b[:name] == 'main' }[:head]
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' }))
    assert @s.dirty?('/f.txt', since: before)
  end

  def test_new_since_returns_only_new_revisions_in_order
    @s.create_file('/f.txt', content: '')
    r1 = @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'a' }))
    r2 = @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' }))
    r3 = @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 2, data: 'c' }))

    found, revs = @s.new_since('/f.txt', r1.first.id)
    assert found
    assert_equal [r2.first.id, r3.first.id], revs.map(&:id)
  end

  def test_new_since_at_head_is_empty
    @s.create_file('/f.txt', content: 'x')
    head = @s.branches('/f.txt').find { |b| b[:name] == 'main' }[:head]
    found, revs = @s.new_since('/f.txt', head)
    assert found
    assert_empty revs
  end

  def test_new_since_stale_revision_not_an_ancestor
    @s.create_file('/f.txt', content: "base\n")          # genesis G
    @s.branch('/f.txt', 'feature')                          # feature head = G
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'm' }), branch: 'main')     # main head = M (parent G)
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'f' }), branch: 'feature')  # feature head = F (parent G)
    main_head = @s.branches('/f.txt').find { |b| b[:name] == 'main' }[:head]

    # M is a sibling of F, not an ancestor of it -> stale/forked since
    found, revs = @s.new_since('/f.txt', main_head, branch: 'feature')
    refute found
    # full first-parent chain head->genesis: F then G
    assert_equal 2, revs.length
  end

  def test_dirty_after_fast_forward
    @s.create_file('/f.txt', content: "a\n")
    @s.branch('/f.txt', 'feature')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'b' }), branch: 'feature')
    main_before = @s.branches('/f.txt').find { |b| b[:name] == 'main' }[:head]
    @s.merge('/f.txt', target: 'main', source: 'feature')
    assert @s.dirty?('/f.txt', since: main_before)
  end

  def test_new_since_on_binary
    @s.create_file('/b.bin', binary: true)
    r1 = @s.write_blob('/b.bin', "\x01".b)
    r2 = @s.write_blob('/b.bin', "\x02".b)
    found, revs = @s.new_since('/b.bin', r1.id)
    assert found
    assert_equal [r2.id], revs.map(&:id)
    assert_equal 'writeBinary', revs.first.change_type
  end
end

class StaleBaseGuardTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_stale_same_chain_still_works
    f = @s.create_file('/f.txt', content: 'X')
    base = f.branches.find_by!(name: 'main').head_revision_id
    4.times { |i| @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: ('A'.ord + i).chr }), priority: i.to_s) }
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'Z' }), base_revision_id: base, priority: 'z')
    assert @s.read('/f.txt').include?('Z')
  end

  def test_off_chain_base_raises
    f = @s.create_file('/f.txt', content: "base\n")
    @s.branch('/f.txt', 'feature')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'M' }))           # main
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'F' }), branch: 'feature') # feature
    main_head = f.branches.find_by!(name: 'main').head_revision_id

    err = assert_raises(RuntimeError) do
      @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'Z' }),
               base_revision_id: main_head, branch: 'feature', priority: 'z')
    end
    assert_match(/not an ancestor/, err.message)
  end

  def test_off_chain_base_does_not_mutate
    f = @s.create_file('/f.txt', content: "base\n")
    @s.branch('/f.txt', 'feature')
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'M' }))            # main advances
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'F' }), branch: 'feature')
    main_head = f.branches.find_by!(name: 'main').head_revision_id
    revs_before = f.revisions.count

    assert_raises(RuntimeError) do
      @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 1, startChar: 0, data: 'Z' }),
               base_revision_id: main_head, branch: 'feature')
    end
    assert_equal revs_before, f.revisions.count
    assert_equal "base\nF", @s.read('/f.txt', branch: 'feature')
  end
end

class PriorityStabilityTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  # The priority persisted on a revision must be the hash of the ORIGINAL
  # incoming delta, frozen before OT rewrites coordinates. If it were
  # recomputed from transformed coordinates, the stored value would never
  # match what the transform used to tie-break, breaking deterministic
  # convergence across replicas.
  def test_transformed_write_persists_original_priority
    f = @s.create_file('/f.txt', content: 'abc')
    base = f.branches.find_by!(name: 'main').head_revision_id
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataMultiLine', { startLine: 0, startChar: 0, data: 'X' }), priority: 'rev-c1')

    incoming = DbfsV2::Delta.new('insertDataMultiLine', { startLine: 0, startChar: 2, data: 'I' })
    expected = incoming.priority_for(nil)
    revs = @s.write('/f.txt', incoming, base_revision_id: base)

    refute_empty revs
    assert revs.all? { |r| r.priority == expected },
           "stored priority should be the original hash #{expected[0, 12]}, got #{revs.map { |r| r.priority[0, 12] }.inspect}"
  end

  def test_multi_hop_transform_keeps_one_priority
    f = @s.create_file('/f.txt', content: 'abc')
    base = f.branches.find_by!(name: 'main').head_revision_id
    3.times { |i| @s.write('/f.txt', DbfsV2::Delta.new('insertDataMultiLine', { startLine: 0, startChar: 0, data: ('X'.ord + i).chr }), priority: "rev-#{i}") }

    incoming = DbfsV2::Delta.new('insertDataMultiLine', { startLine: 0, startChar: 2, data: 'I' })
    expected = incoming.priority_for(nil)
    revs = @s.write('/f.txt', incoming, base_revision_id: base)

    # a single logical op may split across transforms but must carry one priority
    assert_equal 1, revs.map(&:priority).uniq.size
    assert_equal expected, revs.first.priority
  end
end
