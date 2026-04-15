# Seeded dev user (Devise-compatible)
User.create!(email: 'dev@example.com', password: 'password', password_confirmation: 'password') unless User.exists?(email: 'dev@example.com')
