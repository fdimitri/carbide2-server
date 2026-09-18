# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'
require 'tmpdir'

# BranchView: a Store bound to a project branch, so flusher/watcher/loader code
# written for main's tree mirrors a branch's tree unchanged (ADR-042 §materialize).
class BranchViewTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
    @s.create_folder('/lib')
    @s.create_file('/lib/a.rb', content: "a1\n")
    @s.create_file('/README', content: "readme\n")
    @s.create_project_branch('feature')
    @v = @s.for_branch('feature')
  end

  def set(data) = d('setContents', { data: data })
  def main_head = @s.branches('/lib/a.rb').find { |b| b[:name] == 'main' }[:head]

  def test_main_view_is_the_store_itself
    assert_same @s, @s.for_branch('main')
    assert_equal 'feature', @v.branch_name
    assert_equal @s.project_id, @v.project_id
  end

  def test_view_forces_its_branch_even_when_a_caller_names_another
    @v.write('/lib/a.rb', set("a2 on feature\n"))
    assert_equal "a2 on feature\n", @v.read('/lib/a.rb')
    assert_equal "a2 on feature\n", @v.read('/lib/a.rb', branch: 'main')
    assert_equal "a1\n", @s.read('/lib/a.rb')
    @v.create_file('/only-here.txt', content: "x\n")
    assert @v.find('/only-here.txt')
    assert_nil @s.find('/only-here.txt')
    assert @s.seq.is_a?(Integer), 'unbranched methods fall through'
  end

  def test_text_heads_report_pins_until_written
    a = @s.find('/lib/a.rb')
    heads = @v.text_heads.to_h { |id, path, head| [path, [id, head]] }
    assert_equal a.id, heads['/lib/a.rb'][0]
    assert_equal main_head, heads['/lib/a.rb'][1], 'pinned at fork'
    @v.write('/lib/a.rb', set("a2\n"))
    moved = @v.text_heads.to_h { |_, path, head| [path, head] }
    refute_equal heads['/lib/a.rb'][1], moved['/lib/a.rb']
    assert_equal main_head, @s.text_heads.to_h { |_, p, h| [p, h] }['/lib/a.rb'], 'main untouched'
    assert_equal [a.id], @v.text_heads(node_ids: [a.id]).map(&:first)
  end

  def test_flusher_mirrors_the_branch_tree_not_main
    @v.write('/lib/a.rb', set("a2 on feature\n"))
    @v.create_file('/lib/new.rb', content: "new\n")
    @s.create_file('/main-only.rb', content: "m\n")
    Dir.mktmpdir do |dir|
      n = DbfsV2::Flusher.new(@v, dir).flush_all
      assert_equal 4, n, 'lib/, lib/a.rb, lib/new.rb, README'
      assert_equal "a2 on feature\n", File.read(File.join(dir, 'lib/a.rb'))
      assert_equal "new\n", File.read(File.join(dir, 'lib/new.rb'))
      refute File.exist?(File.join(dir, 'main-only.rb'))
    end
  end

  def test_loader_imports_disk_into_the_branch
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'src'))
      File.write(File.join(dir, 'src/fromdisk.rb'), "disk\n")
      FsLoader.new(project_id: @s.project_id, root_path: dir, verbose: false, branch: 'feature').load!
      assert_equal "disk\n", @v.read('/src/fromdisk.rb')
      assert_nil @s.find('/src/fromdisk.rb'), 'main does not see it'
    end
  end
end
