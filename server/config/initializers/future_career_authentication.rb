# frozen_string_literal: true

Rails.application.config.after_initialize do
  # Match Future Career password recovery; keep any stricter deployment setting.
  Spree::Config[:minimum_password_length] = [Spree::Config[:minimum_password_length], 10].max
  Spree.store_authentication_strategies.add(:future_career, FutureCareer::AuthenticationStrategy)
end

Rails.application.config.to_prepare do
  Spree.api.customer_serializer = FutureCareer::CustomerSerializer
  controller = Spree::Api::V3::Store::CustomersController
  extension = FutureCareer::CustomerPasswordUpdate
  controller.prepend(extension) unless controller.ancestors.include?(extension)
end
