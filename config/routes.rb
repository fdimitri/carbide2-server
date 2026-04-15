Rails.application.routes.draw do
  devise_for :users

  namespace :api, defaults: { format: :json } do
    resources :projects, only: [] do
      resources :terminals, only: [:create], controller: 'terminals'
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check

  # To re-enable OAuth in the future:
  # 1. Add :omniauthable to the User model.
  # 2. Restore the omniauth_callbacks controller and route mapping.
  # 3. Add session middleware if running in API-only mode.
end
