class AddVisibilityToAgentConversations < ActiveRecord::Migration[8.1]
  def change
    # Default 'project' = anyone in the project can see/load the conversation
    # transcript and watch live as it streams.
    # 'private' = only the originating user_id can see it.
    # Owner can flip via agent/set_visibility.
    add_column :agent_conversations, :visibility, :string,
               default: 'project', null: false

    # Recent-conversations dropdown lists by (project, last_activity_at).
    # Existing idx_agent_convos_recent is (project, user, last_activity) —
    # not selective enough now that we list across users in a project.
    add_index :agent_conversations, [:project_id, :last_activity_at],
              name: 'idx_agent_convos_project_recent'
  end
end
