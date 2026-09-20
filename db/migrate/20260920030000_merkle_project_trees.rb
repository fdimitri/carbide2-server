# frozen_string_literal: true
require 'digest'
# Path ops used to insert every path on every running node. A directory is
# now a content-addressed object (sorted children → SHA256); a project node
# points at a root tree. Unchanged sibling trees are reused, so a path op
# writes the dirty spine rather than the whole project.
class MerkleProjectTrees < ActiveRecord::Migration[8.1]
  def up
    create_table :project_trees, id: :string, limit: 64 do |t|
      t.timestamps
    end

    create_table :project_tree_entries do |t|
      t.string :tree_id, limit: 64, null: false
      t.string :name, null: false
      t.uuid   :file_node_id, null: false
      t.string :ftype, null: false, default: 'file'
      t.string :child_tree_id, limit: 64
      t.uuid   :revision_id
      t.timestamps
    end
    add_index :project_tree_entries, %i[tree_id name], unique: true, name: 'index_project_tree_entries_name'
    add_index :project_tree_entries, %i[tree_id file_node_id], unique: true, name: 'index_project_tree_entries_node'
    add_index :project_tree_entries, :child_tree_id

    add_column :project_nodes, :root_tree_id, :string, limit: 64
    add_index  :project_nodes, :root_tree_id

    backfill_trees!
    drop_table :project_node_entries
  end

  def down
    create_table :project_node_entries do |t|
      t.string :project_node_id, limit: 64, null: false
      t.uuid   :file_node_id, null: false
      t.string :path, null: false
      t.string :ftype, null: false, default: 'file'
      t.uuid   :content_branch_id
      t.uuid   :revision_id
      t.timestamps
    end
    add_index :project_node_entries, %i[project_node_id path], unique: true, name: 'index_project_node_entries_path'
    add_index :project_node_entries, %i[project_node_id file_node_id], unique: true, name: 'index_project_node_entries_node'

    say_with_time 'flatten merkle trees back onto project_node_entries' do
      select_all('SELECT id, root_tree_id FROM project_nodes').each do |n|
        next unless n['root_tree_id']
        flatten_tree(n['root_tree_id']).each do |row|
          execute <<~SQL
            INSERT INTO project_node_entries (
              project_node_id, file_node_id, path, ftype, revision_id, created_at, updated_at
            ) VALUES (
              #{quote(n['id'])}, #{quote(row[:file_node_id])}, #{quote(row[:path])},
              #{quote(row[:ftype])}, #{row[:revision_id] ? quote(row[:revision_id]) : 'NULL'},
              now(), now()
            )
          SQL
        end
      end
    end

    remove_column :project_nodes, :root_tree_id
    drop_table :project_tree_entries
    drop_table :project_trees
  end

  private

  def backfill_trees!
    say_with_time 'backfill merkle trees from project_node_entries' do
      @tree_cache = {}
      select_all('SELECT id FROM project_nodes').each do |n|
        rows = select_all(<<~SQL).map { |r| r }
          SELECT path, file_node_id, ftype, revision_id
          FROM project_node_entries
          WHERE project_node_id = #{quote(n['id'])}
          ORDER BY path
        SQL
        root = build_tree(rows)
        execute("UPDATE project_nodes SET root_tree_id = #{quote(root)} WHERE id = #{quote(n['id'])}")
      end
    end
  end

  def build_tree(rows)
    dirs = { '/' => {} }
    rows.each do |r|
      path = r['path']
      next if path.blank? || path == '/'
      parent = File.dirname(path)
      parent = '/' if parent == '.'
      name = File.basename(path)
      dirs[parent] ||= {}
      dirs[path] ||= {} if r['ftype'] == 'folder'
      dirs[parent][name] = {
        name: name, file_node_id: r['file_node_id'], ftype: r['ftype'],
        child_tree_id: nil, revision_id: r['revision_id']
      }
    end
    write_dir('/', dirs)
  end

  def write_dir(path, dirs)
    entries = dirs[path] || {}
    entries.each_value do |e|
      next unless e[:ftype] == 'folder'
      child = path == '/' ? "/#{e[:name]}" : "#{path}/#{e[:name]}"
      e[:child_tree_id] = write_dir(child, dirs)
    end
    put_tree(entries.values)
  end

  def put_tree(entries)
    kids = entries.sort_by { |e| e[:name].to_s }
    id = hash_tree(kids)
    return id if @tree_cache[id]
    now = quote(Time.now.utc)
    execute <<~SQL
      INSERT INTO project_trees (id, created_at, updated_at)
      VALUES (#{quote(id)}, #{now}, #{now})
      ON CONFLICT (id) DO NOTHING
    SQL
    kids.each do |e|
      execute <<~SQL
        INSERT INTO project_tree_entries (
          tree_id, name, file_node_id, ftype, child_tree_id, revision_id, created_at, updated_at
        ) VALUES (
          #{quote(id)}, #{quote(e[:name])}, #{quote(e[:file_node_id])}, #{quote(e[:ftype] || 'file')},
          #{e[:child_tree_id] ? quote(e[:child_tree_id]) : 'NULL'},
          #{e[:revision_id] ? quote(e[:revision_id]) : 'NULL'},
          #{now}, #{now}
        )
        ON CONFLICT (tree_id, name) DO NOTHING
      SQL
    end
    @tree_cache[id] = true
    id
  end

  def hash_tree(entries)
    buf = +"tree\n"
    entries.sort_by { |e| e[:name].to_s }.each do |e|
      buf << "#{e[:name]}\t#{e[:file_node_id]}\t#{e[:ftype] || 'file'}\t#{e[:child_tree_id]}\t#{e[:revision_id]}\n"
    end
    Digest::SHA256.hexdigest(buf)
  end

  def flatten_tree(root_id)
    sql = <<~SQL
      WITH RECURSIVE walk AS (
        SELECT e.name, e.file_node_id, e.ftype, e.child_tree_id, e.revision_id,
               ('/' || e.name) AS path
        FROM project_tree_entries e
        WHERE e.tree_id = #{quote(root_id)}
        UNION ALL
        SELECT c.name, c.file_node_id, c.ftype, c.child_tree_id, c.revision_id,
               (w.path || '/' || c.name) AS path
        FROM project_tree_entries c
        INNER JOIN walk w ON c.tree_id = w.child_tree_id
      )
      SELECT path, file_node_id, ftype, revision_id FROM walk ORDER BY path
    SQL
    select_all(sql).map do |r|
      { path: r['path'], file_node_id: r['file_node_id'], ftype: r['ftype'], revision_id: r['revision_id'] }
    end
  end
end
