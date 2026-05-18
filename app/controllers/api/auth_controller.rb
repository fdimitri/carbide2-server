# API authentication controller for JSON-based login/signup
class Api::AuthController < ActionController::API
  def login
    user = User.find_by(email: auth_params[:email])
    
    if user&.valid_password?(auth_params[:password])
      token = issue_user_token(user)
      render json: {
        user: user_response(user),
        token: token,
        message: 'Login successful'
      }
    else
      render json: {
        error: 'Invalid email or password'
      }, status: :unauthorized
    end
  end

  def signup
    user = User.new(email: auth_params[:email], password: auth_params[:password], password_confirmation: auth_params[:password_confirmation])
    
    if user.save
      token = issue_user_token(user)
      render json: {
        user: user_response(user),
        token: token,
        message: 'Signup successful'
      }, status: :created
    else
      render json: {
        error: 'Signup failed',
        errors: user.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  private

  def auth_params
    params.require(:user).permit(:email, :password, :password_confirmation)
  end

  def user_response(user)
    {
      id: user.id,
      email: user.email
    }
  end

  def issue_user_token(user)
    secret = ENV.fetch('WORKER_JWT_SECRET')
    exp = Time.now.to_i + Integer(ENV.fetch('WORKER_TOKEN_EXPIRY_SECONDS', '3600'))
    
    payload = {
      sub: user.id,
      iat: Time.now.to_i,
      exp: exp,
      scopes: ['user:auth']
    }
    
    JWT.encode(payload, secret, 'HS256')
  end
end
