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

ActiveRecord::Schema[8.1].define(version: 2026_05_20_110000) do
  create_table "chat_channels", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_chat_channels_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_chat_channels_on_project_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.integer "chat_channel_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["chat_channel_id"], name: "index_chat_messages_on_chat_channel_id"
    t.index ["user_id"], name: "index_chat_messages_on_user_id"
  end

  create_table "directory_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.string "cur_name", null: false
    t.string "ftype", default: "file", null: false
    t.integer "owner_id"
    t.integer "project_id", null: false
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
    t.integer "directory_entry_id", null: false
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

  create_table "project_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "flush_bytes"
    t.float "flush_interval_s"
    t.integer "project_id", null: false
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
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_projects_on_user_id"
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
    t.integer "user_id", null: false
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

  add_foreign_key "chat_channels", "projects"
  add_foreign_key "chat_messages", "chat_channels"
  add_foreign_key "chat_messages", "users"
  add_foreign_key "directory_entries", "projects"
  add_foreign_key "file_changes", "directory_entries"
  add_foreign_key "project_settings", "projects"
  add_foreign_key "user_preferences", "users"
end
