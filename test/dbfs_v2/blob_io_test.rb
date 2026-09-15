# frozen_string_literal: true
#
# Blob IO — stateless, S3-style byte interface over binary files, plus the
# client-side cursor (fd emulation, no server state).
require_relative 'dbfs_v2_test_helper'

class BlobIoTest < Minitest::Test
  include StoreTestHelpers
  def setup = @s = setup_store
  def b(s) = s.b

  def bin(path, bytes)
    @s.create_file(path, content: b(bytes), binary: true)
  end

  # --- reads -----------------------------------------------------------------

  def test_read_whole_and_range
    bin('/a', "\x00\x01\x02\x03\x04")
    assert_equal b("\x00\x01\x02\x03\x04"), DbfsV2::BlobIO.read(@s, '/a')
    assert_equal b("\x01\x02"), DbfsV2::BlobIO.read(@s, '/a', offset: 1, length: 2)
    assert_equal b("\x03\x04"), DbfsV2::BlobIO.read(@s, '/a', offset: 3) # to end
  end

  def test_read_past_eof_is_empty_and_offset_clamps
    bin('/a', 'abc')
    assert_equal b(''), DbfsV2::BlobIO.read(@s, '/a', offset: 99)
    assert_equal b('abc'), DbfsV2::BlobIO.read(@s, '/a', offset: -5)
    assert_equal b(''), DbfsV2::BlobIO.read(@s, '/a', offset: 0, length: 0)
  end

  def test_read_rejects_missing_and_text
    assert_raises(RuntimeError) { DbfsV2::BlobIO.read(@s, '/nope') }
    @s.create_file('/t', content: 'text')
    assert_raises(RuntimeError) { DbfsV2::BlobIO.read(@s, '/t') }
  end

  def test_size_and_digest
    bin('/a', 'hello')
    assert_equal 5, DbfsV2::BlobIO.size(@s, '/a')
    assert_equal Digest::SHA256.hexdigest('hello'), DbfsV2::BlobIO.digest(@s, '/a')
  end

  # --- writes ----------------------------------------------------------------

  def test_write_replaces_whole_content
    bin('/a', 'old')
    DbfsV2::BlobIO.write(@s, '/a', 'newer')
    assert_equal b('newer'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_put_creates_then_replaces
    DbfsV2::BlobIO.put(@s, '/p', 'v1')
    assert_equal b('v1'), DbfsV2::BlobIO.read(@s, '/p')
    DbfsV2::BlobIO.put(@s, '/p', 'v2')
    assert_equal b('v2'), DbfsV2::BlobIO.read(@s, '/p')
  end

  def test_append
    bin('/a', 'abc')
    DbfsV2::BlobIO.append(@s, '/a', 'def')
    assert_equal b('abcdef'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_insert_shifts_tail
    bin('/a', 'ace')
    DbfsV2::BlobIO.insert(@s, '/a', 1, 'b')
    assert_equal b('abce'), DbfsV2::BlobIO.read(@s, '/a')
    DbfsV2::BlobIO.insert(@s, '/a', 0, 'X')
    assert_equal b('Xabce'), DbfsV2::BlobIO.read(@s, '/a')
    DbfsV2::BlobIO.insert(@s, '/a', 99, 'Z') # clamps to size -> append
    assert_equal b('XabceZ'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_overwrite_keeps_tail
    bin('/a', '0123456789')
    DbfsV2::BlobIO.overwrite(@s, '/a', 2, 3, 'XY')  # replace "234" with "XY"
    assert_equal b('01XY56789'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_overwrite_to_end_with_nil_length
    bin('/a', '0123456789')
    DbfsV2::BlobIO.overwrite(@s, '/a', 5, nil, 'Z')
    assert_equal b('01234Z'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_truncate
    bin('/a', '0123456789')
    DbfsV2::BlobIO.truncate(@s, '/a', 4)
    assert_equal b('0123'), DbfsV2::BlobIO.read(@s, '/a')
    DbfsV2::BlobIO.truncate(@s, '/a', 99) # no-op past size
    assert_equal b('0123'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_each_write_is_a_revision_and_history_is_readable
    bin('/a', 'v1')
    r1 = head(@s, '/a')
    DbfsV2::BlobIO.append(@s, '/a', 'v2')
    assert_equal b('v1'), @s.read('/a', revision_id: r1)
    assert_equal b('v1v2'), @s.read('/a')
    assert_equal 2, Revision.where(file_node_id: @s.find('/a').id).count
  end

  # --- copy (content-addressed) ----------------------------------------------

  def test_copy_reuses_the_same_blob_digest
    bin('/a', 'shared bytes')
    DbfsV2::BlobIO.copy(@s, '/a', '/b')
    assert_equal b('shared bytes'), DbfsV2::BlobIO.read(@s, '/b')
    assert_equal DbfsV2::BlobIO.digest(@s, '/a'), DbfsV2::BlobIO.digest(@s, '/b')
    assert_equal 1, Blob.where(digest: DbfsV2::BlobIO.digest(@s, '/a')).count
  end

  # --- cursor (client-side fd) -----------------------------------------------

  def test_cursor_read_seek_tell
    bin('/a', '0123456789')
    cur = @s.blob_cursor('/a')
    assert_equal 10, cur.size
    assert_equal b('0123'), cur.read(4)
    assert_equal 4, cur.tell
    assert_equal b('89'), cur.seek(-2, :end) && cur.read
    assert_equal b('2345'), cur.seek(2) && cur.read(4)
    assert_equal b('56789'), cur.seek(5, :set) && cur.read
    assert cur.eof?
    assert_equal b(''), cur.read
  end

  def test_cursor_read_all_and_rewind
    bin('/a', 'abcdef')
    cur = @s.blob_cursor('/a')
    cur.read(3)
    assert_equal b('abcdef'), cur.read_all
    assert_equal b('abcdef'), cur.rewind && cur.read
  end

  def test_cursor_is_pinned_a_concurrent_write_does_not_move_it
    bin('/a', 'version1')
    cur = @s.blob_cursor('/a')
    DbfsV2::BlobIO.write(@s, '/a', 'version2-different')
    assert_equal b('version1'), cur.read, 'cursor still reads the revision it opened'
    assert_equal b('version2-different'), DbfsV2::BlobIO.read(@s, '/a')
  end

  def test_cursor_rejects_bad_whence_and_closed_read
    bin('/a', 'x')
    cur = @s.blob_cursor('/a')
    assert_raises(ArgumentError) { cur.seek(0, :sideways) }
    cur.close
    assert_raises(IOError) { cur.read }
  end
end
