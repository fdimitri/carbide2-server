# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_20_040000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "agent_conversations", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.integer "forked_at_turn"
    t.bigint "forked_from_id"
    t.datetime "last_activity_at"
    t.bigint "project_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "uuid", null: false
    t.string "visibility", default: "project", null: false
    t.index ["agent_id"], name: "index_agent_conversations_on_agent_id"
    t.index ["forked_from_id"], name: "index_agent_conversations_on_forked_from_id"
    t.index ["project_id", "last_activity_at"], name: "idx_agent_convos_project_recent"
    t.index ["project_id", "user_id", "last_activity_at"], name: "idx_agent_convos_recent"
    t.index ["project_id"], name: "index_agent_conversations_on_project_id"
    t.index ["user_id"], name: "index_agent_conversations_on_user_id"
    t.index ["uuid"], name: "index_agent_conversations_on_uuid", unique: true
  end

  create_table "agent_messages", force: :cascade do |t|
    t.bigint "agent_conversation_id", null: false
    t.bigint "agent_turn_id"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "evicted_at"
    t.integer "expires_at_turn"
    t.string "name"
    t.string "role", null: false
    t.string "tool_call_id"
    t.text "tool_calls_json"
    t.integer "turn", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["agent_conversation_id", "evicted_at"], name: "idx_agent_messages_evicted"
    t.index ["agent_conversation_id", "expires_at_turn"], name: "idx_agent_messages_expiry"
    t.index ["agent_conversation_id", "turn"], name: "index_agent_messages_on_agent_conversation_id_and_turn", unique: true
    t.index ["agent_conversation_id"], name: "index_agent_messages_on_agent_conversation_id"
    t.index ["agent_turn_id"], name: "index_agent_messages_on_agent_turn_id"
  end

  create_table "agent_turn_usages", force: :cascade do |t|
    t.bigint "agent_conversation_id", null: false
    t.bigint "agent_message_id"
    t.integer "cached_tokens"
    t.integer "completion_tokens"
    t.datetime "created_at", null: false
    t.integer "prompt_tokens"
    t.integer "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id", "created_at"], name: "idx_agent_turn_usage_recent"
    t.index ["agent_conversation_id"], name: "index_agent_turn_usages_on_agent_conversation_id"
    t.index ["agent_message_id"], name: "index_agent_turn_usages_on_agent_message_id"
  end

  create_table "agent_turns", force: :cascade do |t|
    t.bigint "agent_conversation_id", null: false
    t.datetime "created_at", null: false
    t.integer "end_turn"
    t.integer "start_turn", null: false
    t.string "status", default: "in_progress", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id", "start_turn"], name: "index_agent_turns_on_agent_conversation_id_and_start_turn", unique: true
    t.index ["agent_conversation_id"], name: "index_agent_turns_on_agent_conversation_id"
  end

  create_table "agents", force: :cascade do |t|
    t.json "allowed_tools", default: [], null: false
    t.text "api_key"
    t.datetime "created_at", null: false
    t.string "description"
    t.boolean "enabled", default: true, null: false
    t.integer "max_turns"
    t.string "model", null: false
    t.string "name", null: false
    t.json "peak_hours", default: [], null: false
    t.string "provider_url", null: false
    t.string "role", default: "general", null: false
    t.json "sampling", default: {}, null: false
    t.boolean "shell_exec_enabled", default: false, null: false
    t.string "slug", null: false
    t.text "system_prompt", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_agents_on_enabled"
    t.index ["role"], name: "index_agents_on_role"
    t.index ["slug"], name: "index_agents_on_slug", unique: true
  end

  create_table "blobs", primary_key: "digest", id: :string, force: :cascade do |t|
    t.binary "content", null: false
    t.datetime "created_at", null: false
    t.bigint "size", null: false
    t.datetime "updated_at", null: false
  end

  create_table "branch_entries", force: :cascade do |t|
    t.uuid "content_branch_id"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "file_node_id", null: false
    t.string "ftype", default: "file", null: false
    t.string "path", null: false
    t.uuid "project_branch_id", null: false
    t.uuid "revision_id"
    t.datetime "updated_at", null: false
    t.index ["project_branch_id", "file_node_id"], name: "index_branch_entries_node", unique: true
    t.index ["project_branch_id", "path"], name: "index_branch_entries_live_path", unique: true, where: "(deleted_at IS NULL)"
    t.index ["project_branch_id", "path"], name: "index_branch_entries_path"
  end

  create_table "branch_heads", force: :cascade do |t|
    t.uuid "branch_id", null: false
    t.datetime "created_at", null: false
    t.uuid "revision_id", null: false
    t.bigint "seq", null: false
    t.index ["branch_id", "seq"], name: "index_branch_heads_on_branch_id_and_seq"
  end

  create_table "branches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.bigint "deleted_seq"
    t.uuid "file_node_id", null: false
    t.uuid "head_revision_id"
    t.string "name", null: false
    t.uuid "origin_revision_id"
    t.uuid "project_branch_id"
    t.bigint "seq", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["file_node_id", "name"], name: "index_branches_on_file_node_id_and_name_live", unique: true, where: "(deleted_at IS NULL)"
    t.index ["file_node_id"], name: "index_branches_on_file_node_id"
    t.index ["project_branch_id"], name: "index_branches_on_project_branch_id"
  end

  create_table "browser_sessions", force: :cascade do |t|
    t.string "client_sha"
    t.string "client_version"
    t.datetime "created_at", null: false
    t.jsonb "doc", default: {}, null: false
    t.integer "doc_version"
    t.bigint "forked_from_id"
    t.string "name"
    t.bigint "project_id", null: false
    t.uuid "session_uuid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.jsonb "version_history", default: [], null: false
    t.index ["forked_from_id"], name: "index_browser_sessions_on_forked_from_id"
    t.index ["project_id"], name: "index_browser_sessions_on_project_id"
    t.index ["session_uuid"], name: "index_browser_sessions_on_session_uuid", unique: true
    t.index ["user_id"], name: "index_browser_sessions_on_user_id"
  end

  create_table "chat_channels", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_chat_channels_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_chat_channels_on_project_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_channel_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["chat_channel_id"], name: "index_chat_messages_on_chat_channel_id"
    t.index ["user_id"], name: "index_chat_messages_on_user_id"
  end

  create_table "file_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "file_node_id", null: false
    t.string "from_path"
    t.string "ftype", default: "file", null: false
    t.string "kind", null: false
    t.string "path", null: false
    t.uuid "project_branch_id"
    t.bigint "project_id", null: false
    t.bigint "seq", null: false
    t.bigint "user_id"
    t.index ["file_node_id", "seq"], name: "index_file_events_on_file_node_id_and_seq"
    t.index ["project_branch_id", "seq"], name: "index_file_events_on_project_branch_id_and_seq"
    t.index ["project_id", "seq"], name: "index_file_events_on_project_id_and_seq"
  end

  create_table "file_nodes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "binary", default: false, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by"
    t.string "cur_name"
    t.datetime "deleted_at"
    t.string "ftype", default: "file", null: false
    t.bigint "last_size"
    t.datetime "mtime"
    t.string "owner", null: false
    t.uuid "parent_id"
    t.string "path", null: false
    t.string "posix_group"
    t.integer "posix_mode", default: 420, null: false
    t.bigint "project_id", null: false
    t.string "symlink_target"
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_file_nodes_on_parent_id"
    t.index ["project_id", "cur_name"], name: "index_file_nodes_on_project_id_and_cur_name"
    t.index ["project_id", "deleted_at"], name: "index_file_nodes_on_project_id_and_deleted_at"
    t.index ["project_id", "parent_id"], name: "index_file_nodes_on_project_id_and_parent_id"
    t.index ["project_id", "path"], name: "index_file_nodes_on_project_id_and_path", unique: true
  end

  create_table "keyframes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.uuid "file_node_id", null: false
    t.uuid "revision_id", null: false
    t.datetime "updated_at", null: false
    t.index ["file_node_id", "revision_id"], name: "index_keyframes_on_file_node_id_and_revision_id", unique: true
  end

  create_table "project_branches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "base_branch_id"
    t.string "base_node_id", limit: 64
    t.bigint "base_seq"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.bigint "deleted_seq"
    t.string "fork_node_id", limit: 64
    t.bigint "fork_seq"
    t.uuid "forked_from_id"
    t.string "head_node_id", limit: 64
    t.boolean "materialized", default: false, null: false
    t.string "name", null: false
    t.bigint "project_id", null: false
    t.bigint "seq", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["head_node_id"], name: "index_project_branches_on_head_node_id"
    t.index ["project_id", "name"], name: "index_project_branches_live_name", unique: true, where: "(deleted_at IS NULL)"
    t.index ["project_id"], name: "index_project_branches_on_project_id"
  end

  create_table "project_clocks", id: false, force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "seq", default: 0, null: false
    t.index ["project_id"], name: "index_project_clocks_on_project_id", unique: true
  end

  create_table "project_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["project_id"], name: "index_project_memberships_on_project_id"
    t.index ["user_id", "project_id"], name: "index_project_memberships_on_user_id_and_project_id", unique: true
    t.index ["user_id"], name: "index_project_memberships_on_user_id"
  end

  create_table "project_merges", force: :cascade do |t|
    t.bigint "base_seq"
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.bigint "seq", null: false
    t.uuid "source_id", null: false
    t.uuid "target_id", null: false
    t.bigint "user_id"
    t.index ["project_id", "seq"], name: "index_project_merges_on_project_id_and_seq"
  end

  create_table "project_nodes", id: { type: :string, limit: 64 }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", default: "running", null: false
    t.string "name"
    t.string "parent_id", limit: 64
    t.uuid "project_branch_id", null: false
    t.bigint "project_id", null: false
    t.string "root_tree_id", limit: 64
    t.string "second_parent_id", limit: 64
    t.bigint "seq", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["project_branch_id", "seq"], name: "index_project_nodes_on_project_branch_id_and_seq"
    t.index ["project_branch_id"], name: "index_project_nodes_on_project_branch_id"
    t.index ["project_id", "kind"], name: "index_project_nodes_on_project_id_and_kind"
    t.index ["project_id", "name"], name: "index_project_nodes_snapshot_name", unique: true, where: "(((kind)::text = 'snapshot'::text) AND (name IS NOT NULL))"
    t.index ["project_id", "seq"], name: "index_project_nodes_on_project_id_and_seq"
    t.index ["project_id"], name: "index_project_nodes_on_project_id"
    t.index ["root_tree_id"], name: "index_project_nodes_on_root_tree_id"
  end

  create_table "project_settings", force: :cascade do |t|
    t.integer "agent_shell_busy_timeout_s", default: 60, null: false
    t.integer "agent_shell_peek_tail_bytes", default: 1024, null: false
    t.datetime "created_at", null: false
    t.integer "flush_bytes"
    t.float "flush_interval_s"
    t.bigint "project_id", null: false
    t.string "root_path"
    t.string "shell_image"
    t.datetime "updated_at", null: false
    t.integer "upload_max_entries"
    t.integer "upload_max_entry_bytes"
    t.integer "upload_max_total_bytes"
    t.index ["project_id"], name: "index_project_settings_on_project_id", unique: true
  end

  create_table "project_tree_entries", force: :cascade do |t|
    t.string "child_tree_id", limit: 64
    t.datetime "created_at", null: false
    t.uuid "file_node_id", null: false
    t.string "ftype", default: "file", null: false
    t.string "name", null: false
    t.uuid "revision_id"
    t.string "tree_id", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["child_tree_id"], name: "index_project_tree_entries_on_child_tree_id"
    t.index ["tree_id", "file_node_id"], name: "index_project_tree_entries_node", unique: true
    t.index ["tree_id", "name"], name: "index_project_tree_entries_name", unique: true
  end

  create_table "project_trees", id: { type: :string, limit: 64 }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name"
    t.string "repo_url"
    t.datetime "updated_at", null: false
    t.string "uuid"
    t.index ["uuid"], name: "index_projects_on_uuid", unique: true
  end

  create_table "revisions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "branch_id", null: false
    t.text "bridge"
    t.text "change_data"
    t.string "change_type", null: false
    t.uuid "file_node_id", null: false
    t.uuid "parent_id"
    t.string "priority"
    t.bigint "project_id"
    t.uuid "second_parent_id"
    t.bigint "seq", default: 0, null: false
    t.datetime "timestamp", null: false
    t.bigint "user_id"
    t.index ["branch_id", "seq"], name: "index_revisions_on_branch_id_and_seq"
    t.index ["branch_id"], name: "index_revisions_on_branch_id"
    t.index ["file_node_id"], name: "index_revisions_on_file_node_id"
    t.index ["parent_id"], name: "index_revisions_on_parent_id"
    t.index ["project_id", "seq"], name: "index_revisions_on_project_id_and_seq"
    t.index ["second_parent_id"], name: "index_revisions_on_second_parent_id"
  end

  create_table "terminal_recordings", force: :cascade do |t|
    t.bigint "byte_count", default: 0, null: false
    t.integer "cols", default: 80, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "ended_at"
    t.string "file_path", null: false
    t.bigint "project_id", null: false
    t.integer "rows", default: 24, null: false
    t.datetime "started_at", null: false
    t.string "status", default: "recording", null: false
    t.integer "terminal_id", null: false
    t.string "terminal_name"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_terminal_recordings_on_created_by_id"
    t.index ["project_id", "started_at"], name: "index_terminal_recordings_on_project_id_and_started_at"
    t.index ["project_id"], name: "index_terminal_recordings_on_project_id"
  end

  create_table "user_preferences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "date_format"
    t.integer "editor_font_size"
    t.string "first_name"
    t.string "last_name"
    t.boolean "notifications_enabled"
    t.integer "tab_width"
    t.string "theme"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "username"
    t.index ["user_id"], name: "index_user_preferences_on_user_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "control_uuid"
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "updated_at", null: false
    t.index ["control_uuid"], name: "index_users_on_control_uuid", unique: true
  end

  add_foreign_key "agent_conversations", "agent_conversations", column: "forked_from_id"
  add_foreign_key "agent_conversations", "agents"
  add_foreign_key "agent_conversations", "projects"
  add_foreign_key "agent_conversations", "users"
  add_foreign_key "agent_messages", "agent_conversations"
  add_foreign_key "agent_messages", "agent_turns"
  add_foreign_key "agent_messages", "users"
  add_foreign_key "agent_turn_usages", "agent_conversations"
  add_foreign_key "agent_turn_usages", "agent_messages"
  add_foreign_key "agent_turns", "agent_conversations"
  add_foreign_key "branch_heads", "branches", on_delete: :cascade
  add_foreign_key "branches", "file_nodes", on_delete: :cascade
  add_foreign_key "browser_sessions", "browser_sessions", column: "forked_from_id"
  add_foreign_key "browser_sessions", "projects"
  add_foreign_key "browser_sessions", "users"
  add_foreign_key "chat_channels", "projects"
  add_foreign_key "chat_messages", "chat_channels"
  add_foreign_key "chat_messages", "users"
  add_foreign_key "file_events", "file_nodes", on_delete: :cascade
  add_foreign_key "file_events", "projects", on_delete: :cascade
  add_foreign_key "file_nodes", "projects", on_delete: :cascade
  add_foreign_key "keyframes", "file_nodes", on_delete: :cascade
  add_foreign_key "project_clocks", "projects", on_delete: :cascade
  add_foreign_key "project_memberships", "projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "project_settings", "projects"
  add_foreign_key "revisions", "branches", on_delete: :cascade
  add_foreign_key "revisions", "file_nodes", on_delete: :cascade
  add_foreign_key "terminal_recordings", "projects"
  add_foreign_key "terminal_recordings", "users", column: "created_by_id"
  add_foreign_key "user_preferences", "users"
end
