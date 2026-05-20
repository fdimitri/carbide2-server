# User preferences API — GET and PATCH /api/preferences
# Returns and updates the current user's UserPreference record.
class Api::PreferencesController < Api::BaseController
  def show
    render json: preference_json(user_preference)
  end

  def update
    pref = user_preference
    pref.assign_attributes(preference_params)
    pref.save!
    render json: preference_json(pref)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def user_preference
    current_user.user_preference || current_user.create_user_preference!
  end

  def preference_params
    params.permit(
      :first_name, :last_name, :username,
      :timezone, :theme, :date_format,
      :editor_font_size, :tab_width,
      :notifications_enabled
    )
  end

  def preference_json(pref)
    {
      first_name:            pref.first_name,
      last_name:             pref.last_name,
      username:              pref.username,
      timezone:              pref.timezone,
      theme:                 pref.theme,
      date_format:           pref.date_format,
      editor_font_size:      pref.editor_font_size,
      tab_width:             pref.tab_width,
      notifications_enabled: pref.notifications_enabled
    }
  end
end
