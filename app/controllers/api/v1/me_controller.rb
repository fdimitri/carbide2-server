# Authenticated identity for THIS app's users table — the workspace-local
# mirror, not the control-plane user. user_id here is the local users.id
# that every *.user_id FK in this pod points at.
class Api::V1::MeController < Api::BaseController
  def show
    render json: { user_id: current_user.id, email: current_user.email }
  end
end
