# frozen_string_literal: true
# Main's current path index is branch_entries, the same as every other project
# branch. file_nodes.path becomes an identity slot (`/.nodes/<id>`), not a
# location. Existing main trees are copied into the main row's entries, then
# file_nodes paths that were locations are rewritten so they cannot collide
# with a later identity slot.
class UnifyMainOntoBranchEntries < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      INSERT INTO project_branches (id, project_id, name, seq, created_at, updated_at)
      SELECT gen_random_uuid(), p.project_id, 'main', 0, now(), now()
      FROM (SELECT DISTINCT project_id FROM file_nodes) p
      WHERE NOT EXISTS (
        SELECT 1 FROM project_branches pb
        WHERE pb.project_id = p.project_id AND pb.name = 'main' AND pb.deleted_at IS NULL
      );

      INSERT INTO branch_entries (
        project_branch_id, file_node_id, path, ftype,
        revision_id, content_branch_id, deleted_at, created_at, updated_at
      )
      SELECT pb.id, n.id, n.path, n.ftype,
             CASE WHEN n.ftype = 'file' THEN b.head_revision_id END,
             b.id, n.deleted_at, now(), now()
      FROM file_nodes n
      JOIN project_branches pb
        ON pb.project_id = n.project_id AND pb.name = 'main' AND pb.deleted_at IS NULL
      LEFT JOIN branches b
        ON b.file_node_id = n.id AND b.name = 'main' AND b.deleted_at IS NULL
      WHERE n.path <> '/'
        AND n.path NOT LIKE '/.project-branches/%'
        AND NOT EXISTS (
          SELECT 1 FROM branch_entries e
          WHERE e.project_branch_id = pb.id AND e.file_node_id = n.id
        );

      UPDATE file_nodes
      SET path = '/.nodes/' || id::text, parent_id = NULL
      WHERE path <> '/';
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
