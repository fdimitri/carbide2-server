# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class TextVsBinaryGuardsTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_write_rejects_writeBinary_delta
    @s.create_file('/f', content: 'x')
    assert_raises(RuntimeError) { @s.write('/f', d('writeBinary', { sha256: 'x', size: 1 })) }
  end

  def test_write_rejects_binary_node
    @s.create_file('/b', binary: true)
    assert_raises(RuntimeError) { @s.write('/b', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'x' })) }
  end

  def test_write_to_nonexistent_branch_raises
    @s.create_file('/f', content: 'x', branch: 'foo')
    # 'main' was never created -> must raise, not silently fork history
    assert_raises(ActiveRecord::RecordNotFound) do
      @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'y' }), branch: 'main')
    end
  end
end

class TransformExtraTest < Minitest::Test
  T = DbfsV2::Transform
  def b(s) = DbfsV2::Buffer.new(s)
  def d(t, p, pr = nil)
    x = DbfsV2::Delta.new(t, p); x.priority = pr if pr; x
  end

  def apply_hashes(buf, hs)
    hs.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k,_| k == :type }).apply_to(buf) }
    buf
  end

  def converge(base, a, c)
    ap, cp = T.transform(a, c, b(base))
    l = b(base); a.apply_to(l); apply_hashes(l, cp)
    r = b(base); c.apply_to(r); apply_hashes(r, ap)
    assert_equal r.to_s, l.to_s, "diverge: base=#{base.inspect} a=#{a.type} c=#{c.type}"
    l.to_s
  end

  def test_setcontents_vs_insert_converges
    converge('abc', d('setContents', { data: 'XYZ' }), d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'Q' }, 'c'))
  end

  def test_setcontents_vs_delete_converges
    converge('abc', d('setContents', { data: 'XYZ' }), d('deleteDataSingleLine', { startLine: 0, startChar: 1, endChar: 2 }, 'c'))
  end

  def test_setcontents_vs_replace_converges
    converge('abc', d('setContents', { data: 'XYZ' }), d('replaceDataSingleLine', { startLine: 0, startChar: 1, endChar: 2, data: 'R' }, 'c'))
  end

  def test_pcre_vs_pcre_converges
    a = d('pcreReplaceSingleLine', { pattern: 'a', replacement: 'X' })
    c = d('pcreReplaceSingleLine', { pattern: 'b', replacement: 'Y' })
    converge('abc', a, c)
  end

  def test_identical_priority_identical_content_converges
    # Two ops with the SAME content hash (identical payload) must converge and
    # be deterministic. (Different content with a forced-equal priority is a
    # SHA-1 collision / caller bug, not a TP1 guarantee.)
    results = 50.times.map do
      a = d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }, 'same')
      c = d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }, 'same')
      converge('X', a, c)
    end.uniq
    assert_equal 1, results.size, "identical content + priority produced #{results.inspect}"
    assert_equal 'AAX', results.first
  end
end

class ThreeWayConcurrencyTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_three_concurrent_inserts_all_survive
    f = @s.create_file('/f', content: 'X')
    base = f.branches.find_by!(name: 'main').head_revision_id
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'A' }), base_revision_id: base, priority: 'a')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'B' }), base_revision_id: base, priority: 'b')
    @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'C' }), base_revision_id: base, priority: 'c')
    out = @s.read('/f')
    assert_equal %w[A B C], out.delete('X').chars.sort
    assert_equal 3, f.revisions.count - 1  # 1 genesis + 3 concurrent
  end
end

class MoveGuardTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store

  def test_move_onto_occupied_path_raises
    @s.create_file('/a', content: 'a')
    @s.create_file('/b', content: 'b')
    err = assert_raises(RuntimeError) { @s.move('/a', '/b') }
    assert_match(/destination already exists/, err.message)
    assert_equal 'a', @s.read('/a')   # source untouched
  end

  def test_move_special_chars_isolation
    @s.create_file('/foo%', content: 'x')
    @s.create_file('/foo_', content: 'y')
    @s.move('/foo%', '/foo%2')
    assert_equal 'x', @s.read('/foo%2')
    assert_equal 'y', @s.read('/foo_')
  end
end

class SymlinkTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_write_through_symlink
    @s.create_file('/real', content: 'a')
    @s.create_symlink('/link', '/real')
    @s.write('/link', d('insertDataSingleLine', { startLine: 0, startChar: 1, data: 'b' }))
    assert_equal 'ab', @s.read('/real')
    assert_equal 'ab', @s.read('/link')
  end

  def test_dangling_symlink_read_returns_nil_not_raises
    @s.create_symlink('/link', '/missing')
    assert_nil @s.read('/link')
  end

  def test_symlink_cycle_resolves_nil
    @s.create_symlink('/a', '/b')
    @s.create_symlink('/b', '/a')
    assert_nil @s.find('/a').resolve
  end

  def test_symlink_to_folder_resolves_folder
    @s.create_folder('/dir')
    @s.create_symlink('/dirlink', '/dir')
    assert_equal 'folder', @s.resolve('/dirlink').ftype
  end
end

class IsolationAndDuplicateTest < Minitest::Test
  include DbfsV2TestHelpers

  def test_duplicate_path_raises
    @s = setup_store
    @s.create_file('/f', content: 'a')
    assert_raises(ActiveRecord::RecordNotUnique) { @s.create_file('/f', content: 'b') }
  end

  def test_two_projects_same_path_isolated
    pa = new_project_id
    pb = new_project_id
    s1 = DbfsV2::Store.new(pa)
    s2 = DbfsV2::Store.new(pb)
    s1.create_file('/same', content: 'one')
    s2.create_file('/same', content: 'two')
    s1.read('/same') # hydrate cache for proj-a node
    assert_equal 'one', s1.read('/same')
    assert_equal 'two', s2.read('/same')
    s1.write('/same', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 3, data: '!' }))
    assert_equal 'one!', s1.read('/same')
    assert_equal 'two', s2.read('/same')
  end
end

class CoordinateValidationTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_insert_beyond_end_of_line_rejected
    @s.create_file('/f', content: "ab\ncd")
    assert_raises(ArgumentError) do
      @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 9, data: 'x' }))
    end
  end

  def test_insert_beyond_last_line_rejected
    @s.create_file('/f', content: 'ab')
    assert_raises(ArgumentError) do
      @s.write('/f', d('insertDataSingleLine', { startLine: 5, startChar: 0, data: 'x' }))
    end
  end

  def test_delete_beyond_end_rejected
    @s.create_file('/f', content: 'ab')
    assert_raises(ArgumentError) do
      @s.write('/f', d('deleteDataSingleLine', { startLine: 0, startChar: 0, endChar: 9 }))
    end
  end

  def test_valid_boundary_edit_accepted
    @s.create_file('/f', content: "ab\ncd")
    @s.write('/f', d('insertDataSingleLine', { startLine: 1, startChar: 2, data: 'x' }))
    assert_equal "ab\ncdx", @s.read('/f')
  end

  def test_rejection_does_not_mutate
    f = @s.create_file('/f', content: 'ab')
    before = f.revisions.count
    assert_raises(ArgumentError) do
      @s.write('/f', d('insertDataSingleLine', { startLine: 0, startChar: 99, data: 'x' }))
    end
    assert_equal before, f.revisions.count
    assert_equal 'ab', @s.read('/f')
  end
end

class MoveWildcardTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store

  def test_move_dir_with_percent_does_not_match_siblings
    @s.create_folder('/foo%bar')
    @s.create_file('/foo%bar/inner.txt', content: 'inner')
    @s.create_folder('/fooXbar')
    @s.create_file('/fooXbar/other.txt', content: 'other')
    @s.move('/foo%bar', '/moved')

    assert_equal 'inner', @s.read('/moved/inner.txt')
    # the sibling /fooXbar must be untouched
    assert_equal 'other', @s.read('/fooXbar/other.txt')
    refute @s.find('/moved/other.txt')
  end

  def test_move_dir_with_underscore_does_not_match_siblings
    @s.create_folder('/a_b')
    @s.create_file('/a_b/inner.txt', content: 'inner')
    @s.create_folder('/aXb')
    @s.create_file('/aXb/other.txt', content: 'other')
    @s.move('/a_b', '/moved')

    assert_equal 'inner', @s.read('/moved/inner.txt')
    assert_equal 'other', @s.read('/aXb/other.txt')
  end
end

class PcreErrorTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store
  def d(t, p) = DbfsV2::Delta.new(t, p)

  def test_invalid_regex_raises_and_does_not_mutate
    f = @s.create_file('/f', content: 'abc')
    before = f.revisions.count
    assert_raises(RegexpError) do
      @s.write('/f', d('pcreReplaceSingleLine', { pattern: '(', replacement: 'x' }))
    end
    assert_equal before, f.revisions.count
    assert_equal 'abc', @s.read('/f')
  end
end

class CacheEvictionTest < Minitest::Test
  include DbfsV2TestHelpers
  def setup = @s = setup_store

  def test_invalidate_node_forces_rehydrate_and_stays_correct
    f = @s.create_file('/f', content: 'ab')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 2, data: 'c' }))
    DbfsV2::DocumentCache.invalidate_node(f.id)
    assert_equal 'abc', @s.read('/f')
    @s.write('/f', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 3, data: 'd' }))
    assert_equal 'abcd', @s.read('/f')
  end
end

class InsertInsideReplaceInvariantTest < Minitest::Test
  T = DbfsV2::Transform

  def prim(s, f, t = '', pri = 'p')
    DbfsV2::Transform::Prim.new(s, f, t, pri)
  end

  # The doubling split in transform_ri/transform_rd is dead code: overlap is
  # routed to opaque by ambiguous?. Lock that invariant: calling the overlap
  # branches directly must fail loudly, not silently duplicate content.
  def test_transform_ri_inside_is_unreachable_and_raises
    # insert strictly inside a replace region [0, 4)
    ins = prim(2, 2, 'X')
    rep = prim(0, 4, 'R')
    assert_raises(RuntimeError) { T.transform_ri(rep, ins) }
  end

  def test_transform_rd_overlap_is_unreachable_and_raises
    rep = prim(0, 4, 'R')      # replace [0,4)
    del = prim(1, 3)           # delete [1,3) overlaps
    assert_raises(RuntimeError) { T.transform_rd(rep, del) }
  end

  def test_ambiguous_routes_insert_inside_replace
    base = DbfsV2::Buffer.new('abcde')
    ins = DbfsV2::Delta.new('insertDataMultiLine', { startLine: 0, startChar: 2, data: 'X' })
    rep = DbfsV2::Delta.new('replaceDataMultiLine', { startLine: 0, startChar: 1, endLine: 0, endChar: 4, data: 'R' })
    assert T.ambiguous?(T.to_prims(ins, base), T.to_prims(rep, base))
    # and the public transform converges (routed to opaque, no doubled text)
    ap, bp = T.transform(ins, rep, base)
    left = DbfsV2::Buffer.new('abcde'); ins.apply_to(left)
    bp.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k, _| k == :type }).apply_to(left) }
    right = DbfsV2::Buffer.new('abcde'); rep.apply_to(right)
    ap.each { |h| DbfsV2::Delta.new(h[:type], h.reject { |k, _| k == :type }).apply_to(right) }
    assert_equal left.to_s, right.to_s
    refute_includes left.to_s, 'RR'   # no duplicated replacement text
  end
end
