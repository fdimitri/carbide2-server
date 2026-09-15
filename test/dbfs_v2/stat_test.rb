# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

class StatTest < Minitest::Test
  include DbfsV2TestHelpers

  def setup
    @s = setup_store
  end

  def test_cur_name_is_derived_from_path
    n = @s.create_file('/src/app.rb', content: 'x', owner: 'alice', group: 'dev', user_id: 4242)
    assert_equal 'app.rb', n.cur_name
  end

  def test_root_cur_name
    n = @s.create_folder('/')
    assert_equal '/', n.cur_name
  end

  def test_stat_hash_has_all_fields
    @s.create_file('/src/app.rb', content: 'hello', owner: 'alice', group: 'dev', user_id: 4242)
    h = @s.stat('/src/app.rb')
    %i[id path name type binary size revisions posix_mode posix_owner posix_group mtime created_at updated_at created_by last_size].each do |k|
      assert h.key?(k), "stat missing #{k}"
    end
    assert_equal 'app.rb', h[:name]
    assert_equal 'alice', h[:posix_owner]
    assert_equal 'dev', h[:posix_group]
    assert_equal 4242, h[:created_by]
    assert_equal 5, h[:size]
  end

  def test_stat_text_size_is_dynamic
    f = @s.create_file('/f.txt', content: 'ab')
    assert_equal 2, @s.stat('/f.txt')[:size]
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 2, data: 'c' }))
    assert_equal 3, @s.stat('/f.txt')[:size]
  end

  def test_stat_binary_size_from_last_size
    @s.create_file('/b.bin', binary: true, content: "\x00\x01\x02".b)
    assert_equal 3, @s.stat('/b.bin')[:size]
  end

  def test_write_updates_mtime
    f = @s.create_file('/f.txt', content: '')
    m0 = f.mtime
    sleep 0.01
    @s.write('/f.txt', DbfsV2::Delta.new('insertDataSingleLine', { startLine: 0, startChar: 0, data: 'x' }))
    assert f.reload.mtime > m0
  end

  def test_symlink_stat_includes_resolution
    @s.create_file('/real.txt', content: 'target')
    @s.create_symlink('/link.txt', '/real.txt')
    h = @s.stat('/link.txt')
    assert h[:symlink]
    assert_equal '/real.txt', h[:symlink_target]
    assert_equal '/real.txt', h[:resolved_path]
  end

  # --- edge cases -----------------------------------------------------------

  def test_stat_missing_path_is_nil
    assert_nil @s.stat('/nope')
    assert_nil @s.stat('/nope/deeper')
  end

  # Binary size must come from the stored size (blob row / last_size), never
  # from replaying a text log it does not have.
  def test_stat_binary_size_from_blob_after_write_blob
    @s.create_file('/b', binary: true)
    @s.write_blob('/b', ("\x00\x01\x02" * 100).b)
    h = @s.stat('/b')
    assert_equal 300, h[:size]
    assert_equal 300, h[:last_size]
    assert_equal 300, @s.read('/b').bytesize
  end

  def test_stat_dangling_symlink_resolves_to_nil
    @s.create_symlink('/dang', '/missing')
    h = @s.stat('/dang')
    assert h[:symlink], 'dangling link is still a symlink'
    assert_equal '/missing', h[:symlink_target]
    assert_nil h[:resolved_path], 'no target node exists'
  end

end
