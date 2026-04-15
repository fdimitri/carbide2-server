# Minimal User model placeholder for pre-alpha
class User < ActiveRecord::Base
  # Add Devise modules as placeholders. Configure fully in initializers.
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable, :trackable

  # fields: email:string, provider:string, uid:string
end
