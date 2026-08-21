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

ActiveRecord::Schema[8.1].define(version: 2026_08_21_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "agent_conversations", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_activity_at"
    t.bigint "project_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "uuid", null: false
    t.string "visibility", default: "project", null: false
    t.index ["agent_id"], name: "index_agent_conversations_on_agent_id"
    t.index ["project_id", "last_activity_at"], name: "idx_agent_convos_project_recent"
    t.index ["project_id", "user_id", "last_activity_at"], name: "idx_agent_convos_recent"
    t.index ["project_id"], name: "index_agent_conversations_on_project_id"
    t.index ["user_id"], name: "index_agent_conversations_on_user_id"
    t.index ["uuid"], name: "index_agent_conversations_on_uuid", unique: true
  end

  create_table "agent_messages", force: :cascade do |t|
    t.bigint "agent_conversation_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.string "name"
    t.string "role", null: false
    t.string "tool_call_id"
    t.text "tool_calls_json"
    t.integer "turn", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["agent_conversation_id", "turn"], name: "index_agent_messages_on_agent_conversation_id_and_turn", unique: true
    t.index ["agent_conversation_id"], name: "index_agent_messages_on_agent_conversation_id"
  end

  create_table "agents", force: :cascade do |t|
    t.json "allowed_tools", default: [], null: false
    t.text "api_key"
    t.datetime "created_at", null: false
    t.string "description"
    t.boolean "enabled", default: true, null: false
    t.string "model", null: false
    t.string "name", null: false
    t.string "provider_url", null: false
    t.string "role", default: "general", null: false
    t.json "sampling", default: {}, null: false
    t.boolean "shell_exec_enabled", default: false, null: false
    t.string "slug", null: false
    t.text "system_prompt", default: "", null: false
    t.datetime "updated_at", null: false
    t.integer "max_turns"
    t.index ["enabled"], name: "index_agents_on_enabled"
    t.index ["role"], name: "index_agents_on_role"
    t.index ["slug"], name: "index_agents_on_slug", unique: true
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

  create_table "directory_entries", force: :cascade do |t|
    t.boolean "binary", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.string "cur_name", null: false
    t.string "ftype", default: "file", null: false
    t.bigint "last_size"
    t.datetime "mtime"
    t.integer "owner_id"
    t.string "posix_group"
    t.integer "posix_mode"
    t.string "posix_owner"
    t.bigint "project_id", null: false
    t.string "srcpath", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_directory_entries_on_owner_id"
    t.index ["project_id", "srcpath"], name: "index_directory_entries_on_project_id_and_srcpath", unique: true
    t.index ["project_id"], name: "index_directory_entries_on_project_id"
  end

  create_table "file_changes", force: :cascade do |t|
    t.text "change_data"
    t.string "change_type", null: false
    t.datetime "created_at", null: false
    t.bigint "directory_entry_id", null: false
    t.integer "end_char"
    t.integer "end_line"
    t.datetime "mtime"
    t.integer "revision", default: 0, null: false
    t.integer "start_char", default: 0
    t.integer "start_line", default: 0
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["directory_entry_id", "revision"], name: "index_file_changes_on_directory_entry_id_and_revision"
    t.index ["directory_entry_id"], name: "index_file_changes_on_directory_entry_id"
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

  create_table "project_settings", force: :cascade do |t|
    t.integer "agent_shell_busy_timeout_s", default: 60, null: false
    t.datetime "created_at", null: false
    t.integer "flush_bytes"
    t.float "flush_interval_s"
    t.bigint "project_id", null: false
    t.string "root_path"
    t.string "shell_image"
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_project_settings_on_project_id", unique: true
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name"
    t.string "repo_url"
    t.datetime "updated_at", null: false
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
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "email"
    t.string "encrypted_password", default: "", null: false
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.string "provider"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "sign_in_count", default: 0, null: false
    t.string "uid"
    t.datetime "updated_at", null: false
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "agent_conversations", "agents"
  add_foreign_key "agent_conversations", "projects"
  add_foreign_key "agent_conversations", "users"
  add_foreign_key "agent_messages", "agent_conversations"
  add_foreign_key "agent_messages", "users"
  add_foreign_key "browser_sessions", "browser_sessions", column: "forked_from_id"
  add_foreign_key "browser_sessions", "projects"
  add_foreign_key "browser_sessions", "users"
  add_foreign_key "chat_channels", "projects"
  add_foreign_key "chat_messages", "chat_channels"
  add_foreign_key "chat_messages", "users"
  add_foreign_key "directory_entries", "projects"
  add_foreign_key "file_changes", "directory_entries"
  add_foreign_key "project_memberships", "projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "project_settings", "projects"
  add_foreign_key "terminal_recordings", "projects"
  add_foreign_key "terminal_recordings", "users", column: "created_by_id"
  add_foreign_key "user_preferences", "users"
end
