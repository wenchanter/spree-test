# frozen_string_literal: true

Rails.application.config.after_initialize do
  # Match Career Fit password recovery; keep any stricter deployment setting.
  Spree::Config[:minimum_password_length] = [Spree::Config[:minimum_password_length], 10].max
  Spree.store_authentication_strategies.add(:career_fit, CareerFit::AuthenticationStrategy)
end
