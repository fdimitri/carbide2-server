# frozen_string_literal: true
require_relative 'dbfs_v2_test_helper'

# ProjectMerge.branches: a project branch into its parent (and back), the
# whole tree at once — identity by node, content per file, atomic, with
# resolutions for what both sides changed differently.
class ProjectBranchMergeTest < Minitest::Test
  include StoreTestHelpers

  def setup
    @s = setup_store
    @s.create_folder('/lib')
    @s.create_file('/lib/a.rb', content: "a1\n")
    @s.create_file('/lib/b.rb', content: "b1\n")
    @s.create_file('/README', content: "readme\n")
    @s.create_project_branch('feature')
  end

  def ins(line, char, data) = d('insertDataSingleLine', { startLine: line, startChar: char, data: data })
  def set(data) = d('setContents', { data: data })
  def paths(branch = 'main') = @s.state(branch: branch).paths - ['/']
  def merge(**kw) = @s.merge_branches(source: 'feature', **kw)

  def test_one_sided_changes_merge_cleanly_with_identity_intact
    a_id = @s.find('/lib/a.rb').id
    @s.write('/lib/a.rb', ins(0, 2, '-f'), branch: 'feature')                 # content
    @s.move('/lib/b.rb', '/lib/c.rb', branch: 'feature')                     # rename
    @s.delete('/README', branch: 'feature')                                  # delete
    @s.create_file('/lib/new.rb', content: "new\n", branch: 'feature')       # add
    @s.create_folder('/docs', branch: 'feature')
    @s.create_file('/docs/x.md', content: "x\n", branch: 'feature')          # add under a new folder
    new_id = @s.find('/lib/new.rb', branch: 'feature').id
    @s.write('/lib/b.rb', ins(0, 0, 'M'))                                    # main edits the file feature renamed

    pre = merge(dry_run: true)
    assert pre[:dry_run]
    refute pre[:merged]
    assert_empty pre[:conflicts]
    assert_equal %w[add add add content delete move], pre[:actions].map { |a| a[:kind] }.sort
    assert_equal "Mb1\n", @s.read('/lib/b.rb'), 'dry run wrote nothing'
    assert_equal ['/README', '/lib', '/lib/a.rb', '/lib/b.rb'], paths, 'dry run changed nothing'

    r = merge
    assert r[:merged], r.inspect
    assert_empty r[:conflicts]
    assert_equal ['/docs', '/docs/x.md', '/lib', '/lib/a.rb', '/lib/c.rb', '/lib/new.rb'], paths
    assert_equal "a1-f\n", @s.read('/lib/a.rb')
    assert_equal "Mb1\n",  @s.read('/lib/c.rb'), "main's edit survived the rename from feature"
    assert_equal "new\n",  @s.read('/lib/new.rb')
    assert_equal new_id,   @s.find('/lib/new.rb').id, 'the branch-only file kept its identity'
    assert_equal a_id,     @s.find('/lib/a.rb').id
    assert_equal [@s.seq, 'feature'], @s.project_branch('feature').then { |pb| [pb.base_seq, pb.base_branch.name] }, 'next base: feature as merged'

    again = merge(dry_run: true)
    assert_empty again[:actions], 'nothing left to merge'
    assert_empty again[:conflicts]

    # The branch still reads its own view.
    assert_equal ['/docs', '/docs/x.md', '/lib', '/lib/a.rb', '/lib/c.rb', '/lib/new.rb'], paths('feature')
  end

  def test_identity_conflicts_are_reported_and_nothing_is_applied
    @s.move('/lib/a.rb', '/lib/a_main.rb')
    @s.move('/lib/a.rb', '/lib/a_feat.rb', branch: 'feature')                 # rename/rename
    @s.write('/lib/b.rb', ins(0, 0, 'M'))
    @s.delete('/lib/b.rb', branch: 'feature')                                # modify/delete
    @s.delete('/README')
    @s.write('/README', ins(0, 0, 'F'), branch: 'feature')                   # delete/modify
    @s.create_file('/lib/x.rb', content: "main\n")
    @s.create_file('/lib/x.rb', content: "feat\n", branch: 'feature')        # add/collision
    @s.create_file('/ok.txt', content: "ok\n", branch: 'feature')            # clean, but held back

    r = merge
    refute r[:merged]
    kinds = r[:conflicts].to_h { |c| [c[:kind], c] }
    assert_equal %w[add/collision delete/modify modify/delete rename/rename], kinds.keys.sort
    assert_equal '/lib/a_main.rb', kinds['rename/rename'][:ours][:path]
    assert_equal '/lib/a_feat.rb', kinds['rename/rename'][:theirs][:path]
    assert_nil @s.find('/ok.txt'), 'atomic: the clean add waited'
    assert_equal ['/lib', '/lib/a_main.rb', '/lib/b.rb', '/lib/x.rb'], paths

    a  = kinds['rename/rename'][:id]
    b  = kinds['modify/delete'][:id]
    rd = kinds['delete/modify'][:id]
    x  = kinds['add/collision'][:id]
    r2 = merge(resolutions: {
      a  => { action: 'theirs' },                  # take feature's name
      b  => { action: 'ours' },                    # keep main's modified b.rb
      rd => { action: 'theirs' },                  # bring README back with feature's edit
      x  => { action: 'path', path: '/lib/x_feature.rb' },
    })
    assert r2[:merged], r2.inspect
    assert_equal ['/README', '/lib', '/lib/a_feat.rb', '/lib/b.rb', '/lib/x.rb', '/lib/x_feature.rb', '/ok.txt'], paths
    assert_equal "Freadme\n", @s.read('/README')
    assert_equal "Mb1\n",     @s.read('/lib/b.rb')
    assert_equal "main\n",    @s.read('/lib/x.rb')
    assert_equal "feat\n",    @s.read('/lib/x_feature.rb')
  end

  def test_content_conflicts_hold_the_merge_until_resolved_per_file
    @s.write('/lib/a.rb', set("one\nMAIN\nthree\n"))
    @s.write('/lib/a.rb', set("one\nFEAT\nthree\n"), branch: 'feature')
    @s.create_file('/ok.txt', content: "ok\n", branch: 'feature')

    r = merge
    refute r[:merged]
    assert_equal ['content'], r[:conflicts].map { |c| c[:kind] }
    c = r[:conflicts].first
    assert_equal ['/lib/a.rb', 'main'],    c[:ours].values_at(:path, :branch)
    assert_equal ['/lib/a.rb', 'feature'], c[:theirs].values_at(:path, :branch)
    assert_nil @s.find('/ok.txt')

    # The per-file merge tab settles it on main; the project merge then has
    # nothing to do for that file.
    @s.merge('/lib/a.rb', target: 'main', source: 'feature', resolved: "BOTH a1\n")
    r2 = merge
    assert r2[:merged], r2.inspect
    assert_equal "BOTH a1\n", @s.read('/lib/a.rb')
    assert_equal "ok\n", @s.read('/ok.txt')
  end

  def test_folder_rename_carries_its_children_once
    @s.move('/lib', '/src', branch: 'feature')
    @s.write('/src/a.rb', ins(0, 0, 'F'), branch: 'feature')
    r = merge
    assert r[:merged], r.inspect
    assert_equal ['/README', '/src', '/src/a.rb', '/src/b.rb'], paths
    assert_equal "Fa1\n", @s.read('/src/a.rb')
    assert_equal 1, r[:actions].count { |a| a[:kind] == 'move' }, 'one move for the folder'
  end

  def test_parent_into_child_updates_the_branch
    @s.write('/lib/a.rb', ins(0, 0, 'M'))
    @s.create_file('/from_main.txt', content: "m\n")
    @s.write('/lib/b.rb', ins(0, 0, 'F'), branch: 'feature')
    r = @s.merge_branches(source: 'main', target: 'feature')
    assert r[:merged], r.inspect
    assert_equal "Ma1\n", @s.read('/lib/a.rb', branch: 'feature')
    assert_equal "m\n",   @s.read('/from_main.txt', branch: 'feature')
    assert_equal "Fb1\n", @s.read('/lib/b.rb', branch: 'feature')
    assert_equal "b1\n",  @s.read('/lib/b.rb'), 'main untouched'
    # And back: only feature's own change is left.
    back = merge(dry_run: true)
    assert_empty back[:conflicts]
    assert_equal [['content', 'take']], back[:actions].map { |a| [a[:kind], a[:mode]] }
    assert @s.merge_branches(source: 'feature')[:merged]
    assert_equal "Fb1\n", @s.read('/lib/b.rb')
  end

  def test_unrelated_branches_are_refused
    @s.create_project_branch('other')
    assert_raises(ArgumentError) { @s.merge_branches(source: 'feature', target: 'other') }
  end
end
