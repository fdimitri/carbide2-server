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

ActiveRecord::Schema[8.1].define(version: 2026_04_14_001000) do
  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "repo_url"
    t.datetime "updated_at", null: false
  end

  create_table "terminal_sessions", force: :cascade do |t|
    t.integer "cols", default: 80
    t.datetime "created_at", null: false
    t.integer "owner_id"
    t.integer "project_id"
    t.string "pty_cmd"
    t.integer "rows", default: 24
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_terminal_sessions_on_owner_id"
    t.index ["project_id"], name: "index_terminal_sessions_on_project_id"
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

  add_foreign_key "terminal_sessions", "projects"
  add_foreign_key "terminal_sessions", "users", column: "owner_id"
end
