# Seeded dev user (Devise-compatible)
user = User.find_or_create_by!(email: 'dev@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end

# Default project
Project.find_or_create_by!(name: 'Demo Project') do |p|
  p.user = user
  p.description = 'Default project for dev'
end
