require 'test_helper'
require 'tmpdir'

# Integration tests for DirectoryEntry, FileChange, and FsLoader.
#
# Each test works with a real SQLite test DB and a temporary on-disk directory
# that has at least two levels of subdirectories.  File content == filename so
# that read-back can be trivially verified.
#
# Temp dir layout created in setup:
#
#   <tmpdir>/
#     alpha.txt          ("alpha.txt")
#     beta.txt           ("beta.txt")
#     subdir_a/
#       gamma.txt        ("gamma.txt")
#       subdir_b/
#         delta.txt      ("delta.txt")
#         epsilon.txt    ("epsilon.txt")
class DirectoryEntryTest < ActiveSupport::TestCase

  # Disable parallelism so SQLite doesn't fight itself
  parallelize(workers: 1)

  setup do
    @project = projects(:test_project)
    # Wipe any leftover FS data from prior test runs for this project
    DirectoryEntry.where(project_id: @project.id).destroy_all

    # Build a real temporary directory tree
    @tmpdir = Dir.mktmpdir('carbide2_fs_test')
    write_file('alpha.txt')
    write_file('beta.txt')
    FileUtils.mkdir_p(File.join(@tmpdir, 'subdir_a', 'subdir_b'))
    write_file('subdir_a/gamma.txt')
    write_file('subdir_a/subdir_b/delta.txt')
    write_file('subdir_a/subdir_b/epsilon.txt')
  end

  teardown do
    DirectoryEntry.where(project_id: @project.id).destroy_all
    FileUtils.remove_entry_secure(@tmpdir)
  end

  # ---------------------------------------------------------------------------
  # FsLoader — import and basic verification
  # ---------------------------------------------------------------------------

  test "FsLoader imports all files and directories" do
    stats = FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!

    assert stats[:files] >= 5, "expected at least 5 files, got #{stats[:files]}"
    assert stats[:dirs]  >= 2, "expected at least 2 dirs (subdir_a + subdir_b), got #{stats[:dirs]}"
    assert_equal 0, stats[:skipped]
  end

  test "FsLoader is idempotent — second import skips existing files" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    first_count  = FileChange.joins(:directory_entry)
                             .where(directory_entries: { project_id: @project.id })
                             .count

    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    second_count = FileChange.joins(:directory_entry)
                             .where(directory_entries: { project_id: @project.id })
                             .count

    assert_equal first_count, second_count, "second import should not add FileChange rows"
  end

  # ---------------------------------------------------------------------------
  # calc_current — content matches filename
  # ---------------------------------------------------------------------------

  test "calc_current returns content equal to filename for root-level files" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!

    %w[alpha.txt beta.txt].each do |name|
      entry = DirectoryEntry.find_by_project_and_path(@project.id, "/#{name}")
      assert entry, "expected entry for /#{name}"
      assert_equal name, entry.calc_current.strip,
                   "content of /#{name} should equal its filename"
    end
  end

  test "calc_current returns correct content for nested files" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!

    {
      '/subdir_a/gamma.txt'             => 'gamma.txt',
      '/subdir_a/subdir_b/delta.txt'    => 'delta.txt',
      '/subdir_a/subdir_b/epsilon.txt'  => 'epsilon.txt'
    }.each do |path, expected_content|
      entry = DirectoryEntry.find_by_project_and_path(@project.id, path)
      assert entry, "expected entry for #{path}"
      assert_equal expected_content, entry.calc_current.strip,
                   "content of #{path} should equal its filename"
    end
  end

  # ---------------------------------------------------------------------------
  # FileChange — append insert operations, verify calc_current reflects them
  # ---------------------------------------------------------------------------

  test "inserting a character at the start is reflected in calc_current" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    entry = DirectoryEntry.find_by_project_and_path(@project.id, '/alpha.txt')

    FileChange.append!(
      directory_entry_id: entry.id,
      user_id:            nil,
      change_type:        'insertDataSingleLine',
      change_data:        { 'data' => '!', 'startLine' => 0, 'startChar' => 0 }.to_json,
      start_line:         0,
      start_char:         0
    )

    assert_equal '!alpha.txt', entry.calc_current.strip
  end

  test "inserting text in the middle is reflected in calc_current" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    entry = DirectoryEntry.find_by_project_and_path(@project.id, '/alpha.txt')
    # "alpha.txt" → insert "-MODIFIED-" after "alpha" (char 5)
    FileChange.append!(
      directory_entry_id: entry.id,
      user_id:            nil,
      change_type:        'insertDataSingleLine',
      change_data:        { 'data' => '-MODIFIED-', 'startLine' => 0, 'startChar' => 5 }.to_json,
      start_line:         0,
      start_char:         5
    )

    assert_equal 'alpha-MODIFIED-.txt', entry.calc_current.strip
  end

  test "multiple sequential inserts accumulate correctly" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    entry = DirectoryEntry.find_by_project_and_path(@project.id, '/beta.txt')

    # Start: "beta.txt"
    # Insert "(" at position 0 → "(beta.txt"
    FileChange.append!(
      directory_entry_id: entry.id,
      user_id: nil,
      change_type: 'insertDataSingleLine',
      change_data: { 'data' => '(', 'startLine' => 0, 'startChar' => 0 }.to_json,
      start_line: 0, start_char: 0
    )
    # Insert ")" at end → "(beta.txt)"  — content is now 9 chars, insert at pos 9
    FileChange.append!(
      directory_entry_id: entry.id,
      user_id: nil,
      change_type: 'insertDataSingleLine',
      change_data: { 'data' => ')', 'startLine' => 0, 'startChar' => 9 }.to_json,
      start_line: 0, start_char: 9
    )

    assert_equal '(beta.txt)', entry.calc_current.strip
  end

  test "setContents after inserts replaces all content" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    entry = DirectoryEntry.find_by_project_and_path(@project.id, '/alpha.txt')

    FileChange.append!(
      directory_entry_id: entry.id, user_id: nil,
      change_type: 'insertDataSingleLine',
      change_data: { 'data' => 'IGNORED', 'startLine' => 0, 'startChar' => 0 }.to_json,
      start_line: 0, start_char: 0
    )
    FileChange.append!(
      directory_entry_id: entry.id, user_id: nil,
      change_type: 'setContents',
      change_data: 'completely replaced',
      start_line: 0, start_char: 0
    )

    assert_equal 'completely replaced', entry.calc_current
  end

  test "deleteDataSingleLine removes the expected characters" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    entry = DirectoryEntry.find_by_project_and_path(@project.id, '/alpha.txt')
    # "alpha.txt" — delete ".txt" (chars 5..9)
    FileChange.append!(
      directory_entry_id: entry.id, user_id: nil,
      change_type: 'deleteDataSingleLine',
      change_data: { 'startLine' => 0, 'startChar' => 5, 'endChar' => 9 }.to_json,
      start_line: 0, start_char: 5, end_line: 0, end_char: 9
    )

    assert_equal 'alpha', entry.calc_current.strip
  end

  # ---------------------------------------------------------------------------
  # mkdir_p! and tree_for_project
  # ---------------------------------------------------------------------------

  test "mkdir_p! creates all intermediate directories" do
    DirectoryEntry.mkdir_p!(project_id: @project.id, srcpath: '/a/b/c', user_id: nil)

    assert DirectoryEntry.find_by_project_and_path(@project.id, '/'),    "root missing"
    assert DirectoryEntry.find_by_project_and_path(@project.id, '/a'),   "/a missing"
    assert DirectoryEntry.find_by_project_and_path(@project.id, '/a/b'), "/a/b missing"
    assert DirectoryEntry.find_by_project_and_path(@project.id, '/a/b/c'), "/a/b/c missing"
  end

  test "tree_for_project returns nested structure after import" do
    FsLoader.new(project_id: @project.id, root_path: @tmpdir).load!
    tree = DirectoryEntry.tree_for_project(@project.id)

    assert tree.is_a?(Hash), "tree should be a Hash"
    assert tree[:children].is_a?(Array), "root should have :children"

    all_names = collect_names(tree)
    assert_includes all_names, 'alpha.txt'
    assert_includes all_names, 'gamma.txt'
    assert_includes all_names, 'delta.txt'
    assert_includes all_names, 'subdir_a'
    assert_includes all_names, 'subdir_b'
  end

  private

  # Write a file whose content equals its relative path from @tmpdir basename
  def write_file(rel_path)
    full = File.join(@tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, File.basename(rel_path))
  end

  def collect_names(node, acc = [])
    acc << node[:name] if node[:name] && node[:name] != '/'
    Array(node[:children]).each { |c| collect_names(c, acc) }
    acc
  end
end
