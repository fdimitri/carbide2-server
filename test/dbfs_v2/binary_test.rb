# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class BinaryTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_write_and_read_blob
    @s.create_file('/b.bin', binary: true)
    bytes = "\x00\x01\x02\xFF".b
    @s.write_blob('/b.bin', bytes)
    assert_equal bytes, @s.read('/b.bin')
  end

  def test_read_binary_is_ascii_8bit
    @s.create_file('/b.bin', binary: true)
    @s.write_blob('/b.bin', "\x00\x01".b)
    assert_equal Encoding::ASCII_8BIT, @s.read('/b.bin').encoding
  end

  def test_each_write_is_a_revision
    f = @s.create_file('/b.bin', binary: true)
    @s.write_blob('/b.bin', "\x00".b)
    @s.write_blob('/b.bin', "\x00\x01".b)
    assert_equal 2, f.revisions.count
  end

  def test_reconstruct_specific_binary_revision
    f = @s.create_file('/b.bin', binary: true)
    r1 = @s.write_blob('/b.bin', "\x01".b)
    r2 = @s.write_blob('/b.bin', "\x02".b)
    assert_equal "\x01".b, DbfsV2::Content.at(f, r1.id)
    assert_equal "\x02".b, DbfsV2::Content.at(f, r2.id)
  end

  def test_content_addressed_dedup
    f = @s.create_file('/b.bin', binary: true)
    r1 = @s.write_blob('/b.bin', "\xAA".b)
    r2 = @s.write_blob('/b.bin', "\xAA".b)   # same bytes -> same digest
    assert_equal r1.payload['sha256'], r2.payload['sha256']
  end

  def test_different_content_creates_distinct_blobs
    f = @s.create_file('/b.bin', binary: true)
    r1 = @s.write_blob('/b.bin', "\xAA".b)
    r2 = @s.write_blob('/b.bin', "\xBB".b)
    refute_equal r1.payload['sha256'], r2.payload['sha256']
  end

  def test_binary_branching_fast_forward
    @s.create_file('/b.bin', binary: true, content: "\x01".b)
    @s.branch('/b.bin', 'feature')
    @s.write_blob('/b.bin', "\x01\x02".b, branch: 'feature')
    res = @s.merge('/b.bin', target: 'main', source: 'feature')
    assert res[:merged]
    assert_equal "\x01\x02".b, @s.read('/b.bin', branch: 'main')
  end

  def test_write_blob_rejects_text_file
    @s.create_file('/t.txt', content: 'hi')
    assert_raises(RuntimeError) { @s.write_blob('/t.txt', "\x00".b) }
  end

  def test_write_blob_import_alias
    @s.create_file('/b.bin', binary: true)
    @s.import_blob('/b.bin', "\x42".b)
    assert_equal "\x42".b, @s.read('/b.bin')
  end

  # The flusher does NOT write binaries (their live copy is on the PVC via the
  # ingest path; writing them from the DB would make the flusher a second writer
  # to the authoritative working area). Text is still flushed. See decisions #28.
  def test_flusher_does_not_write_binaries_but_writes_text
    @s.create_file('/b.bin', binary: true, content: "\x00\x01\x02".b)
    @s.create_file('/t.txt', content: 'hello')
    fl = DbfsV2::Flusher.new(@s, "/tmp/dbfs2_bin_#{SecureRandom.hex(4)}")
    fl.flush_all

    refute File.exist?(fl.disk_path('/b.bin')), 'binary must not be flushed'
    assert_equal 'hello', File.read(fl.disk_path('/t.txt')), 'text is still flushed'
    FileUtils.rm_rf(fl.root_path)
  end
end
