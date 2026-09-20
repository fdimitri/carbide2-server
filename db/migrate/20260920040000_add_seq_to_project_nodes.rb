# frozen_string_literal: true
# Stamp every project node with the project clock so a cut S can name the
# path tree (this node) and the content-line heads (reflog seq ≤ S). Left
# out of the node hash: two writers of the same tree still hash-cons.
class AddSeqToProjectNodes < ActiveRecord::Migration[8.1]
  def up
    add_column :project_nodes, :seq, :bigint
    say_with_time 'backfill project_nodes.seq from the clock' do
      select_all('SELECT id, project_id FROM project_nodes ORDER BY created_at, id').each do |n|
        seq = select_value(<<~SQL)
          INSERT INTO project_clocks (project_id, seq) VALUES (#{n['project_id']}, 1)
          ON CONFLICT (project_id) DO UPDATE SET seq = project_clocks.seq + 1
          RETURNING seq
        SQL
        execute("UPDATE project_nodes SET seq = #{seq.to_i} WHERE id = #{quote(n['id'])}")
      end
    end
    change_column_null :project_nodes, :seq, false
    add_index :project_nodes, %i[project_id seq]
    add_index :project_nodes, %i[project_branch_id seq]
  end

  def down
    remove_index :project_nodes, %i[project_branch_id seq]
    remove_index :project_nodes, %i[project_id seq]
    remove_column :project_nodes, :seq
  end
end
