Rails.application.routes.draw do
  devise_for :users

  namespace :api, defaults: { format: :json } do
    # Authentication endpoints
    post '/login',  to: 'auth#login'
    post '/signup', to: 'auth#signup'

    resources :projects do
      member do
        post  :ws_token
        patch :set_root
      end
      resources :chat_channels, only: [:index, :create], controller: 'chat_channels' do
        resources :chat_messages, only: [:index, :create], controller: 'chat_messages'
      end
      # Database-backed virtual filesystem
      resources :directory_entries, only: [], path: 'fs', controller: 'directory_entries' do
        collection do
          get    'tree',    action: :tree
          get    'content', action: :content
          post   'files',   action: :create_file
          post   'dirs',    action: :create_dir
          patch  'rename',  action: :rename
          delete 'entry',   action: :destroy_entry
        end
      end
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check

  # To re-enable OAuth in the future:
  # 1. Add :omniauthable to the User model.
  # 2. Restore the omniauth_callbacks controller and route mapping.
  # 3. Add session middleware if running in API-only mode.
end
