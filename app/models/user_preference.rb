# UserPreference — one row per user, always present (created via User after_create).
# All preference columns are nullable; nil means "use application default".
class UserPreference < ApplicationRecord
  belongs_to :user

  VALID_DATE_FORMATS = %w[relative absolute].freeze
  VALID_THEMES       = %w[carbide_default].freeze

  validates :username,          uniqueness: { allow_nil: true }, length: { maximum: 32, allow_nil: true }
  validates :editor_font_size,  numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :tab_width,         inclusion: { in: [2, 4] }, allow_nil: true
  validates :date_format,       inclusion: { in: VALID_DATE_FORMATS }, allow_nil: true
  validates :theme,             inclusion: { in: VALID_THEMES }, allow_nil: true
  validate  :timezone_is_valid_iana, if: -> { timezone.present? }

  private

  def timezone_is_valid_iana
    TZInfo::Timezone.get(timezone)
  rescue TZInfo::InvalidTimezoneIdentifier
    errors.add(:timezone, 'is not a valid IANA timezone identifier')
  end
end
