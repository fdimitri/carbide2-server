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
ProjectMembership.find_or_create_by!(user: dev_user, project: project)
ProjectMembership.find_or_create_by!(user: admin_user, project: project)


