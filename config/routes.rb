Rails.application.routes.draw do
  devise_for :users

  # Cluster-wide landing page at /. The IngressRoute sends Path(`/`) here.
  root to: 'landing#index'
  get '/about', to: 'landing#about'

  namespace :api, defaults: { format: :json } do
    # Authentication endpoints
    post '/login',  to: 'auth#login'
    post '/signup', to: 'auth#signup'

    # User preferences
    get   '/preferences', to: 'preferences#show'
    patch '/preferences', to: 'preferences#update'

    resources :projects do
      member do
        post  :ws_token
        patch :set_root
        get   :settings
        patch :settings, action: :update_settings
        post  :import_from_git
      end
      resources :chat_channels, only: [:index, :create], controller: 'chat_channels' do
        resources :chat_messages, only: [:index, :create], controller: 'chat_messages'
      end
      # Database-backed virtual filesystem
      resources :directory_entries, only: [], path: 'fs', controller: 'directory_entries' do
        collection do
          get    'tree',    action: :tree
          get    'content', action: :content
          get    'stat',    action: :stat
          get    'blob',    action: :blob
          post   'files',   action: :create_file
          post   'dirs',    action: :create_dir
          patch  'rename',  action: :rename
          delete 'entry',   action: :destroy_entry
          post   'upload',  action: :upload
          post   'import',  action: :import_from_disk
        end
      end

      # Terminal recordings — asciinema cast files for past PTY sessions.
      # Index + per-recording cast download + DELETE. WS push of new rows
      # comes via the worker; this REST surface is for browsing + replay.
      resources :terminal_recordings, only: [:index, :show, :destroy], path: 'recordings' do
        member do
          get :cast
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
