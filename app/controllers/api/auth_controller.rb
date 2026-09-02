# API authentication controller. Login is handled by the control plane;
# the workspace client mints a workspace:api token from control directly
# (ADR-023) and presents it as a bearer on every REST request. This controller
# only keeps the signup redirect notice.
class Api::AuthController < ActionController::API
  def signup
    render json: {
      error: 'Sign up is handled by the control plane. Create your account at /login on the dashboard.'
    }, status: :method_not_allowed
  end

  private

  def auth_params
    params.require(:user).permit(:email, :password, :password_confirmation)
  end
end
