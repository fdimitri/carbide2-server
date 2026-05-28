# OmniAuth callbacks are disabled for now. The class is defined as an empty
# subclass so Zeitwerk's eager_load (production) can resolve the constant
# matching the file path. Restore the action methods to re-enable OAuth.
class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  # def github
  #   handle_oauth
  # end
  #
  # def google_oauth2
  #   handle_oauth
  # end
  #
  # def handle_oauth
  #   auth = request.env['omniauth.auth']
  #   user = User.find_or_create_by(provider: auth.provider, uid: auth.uid) do |u|
  #     u.email = auth.info.email
  #   end
  #
  #   sign_in_and_redirect user
  # end
end
