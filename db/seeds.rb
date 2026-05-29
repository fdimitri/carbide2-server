# Seeded dev user (Devise-compatible)
dev_user = User.find_or_create_by!(email: 'dev@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end
admin_user = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end

# Ensure dev user has a preferences row (after_create handles new signups)
dev_user.create_user_preference! unless dev_user.user_preference

# Default project — create then grant dev_user access via membership
project = Project.find_or_create_by!(name: 'Demo Project') do |p|
  p.description = 'Default project for dev'
end
# Backfill for projects created before the after_create hook existed.
project.ensure_project_setting!
ProjectMembership.find_or_create_by!(user: dev_user, project: project)
ProjectMembership.find_or_create_by!(user: admin_user, project: project)

# Seed a small in-VFS file tree so the IDE has something to open on a fresh
# cluster. Idempotent: each create_file! is wrapped so reruns are no-ops if the
# srcpath already exists. The VFS is independent of any on-disk path.
seed_files = {
  '/README.md'        => "# Demo Project\n\nThis is a seeded project for local dev.\n",
  '/src/main.rb'      => "puts 'hello from the demo project'\n",
  '/src/lib/util.rb'  => <<~'RUBY',
    module Util
      def self.greet(name) = "hi, #{name}"
    end
  RUBY
  '/docs/notes.txt'   => "scratch notes\n",
}
seed_files.each do |path, body|
  next if DirectoryEntry.exists?(project_id: project.id, srcpath: path)
  DirectoryEntry.create_file!(
    project_id: project.id,
    srcpath: path,
    user_id: dev_user.id,
    data: body,
    mkdirp: true
  )
end


