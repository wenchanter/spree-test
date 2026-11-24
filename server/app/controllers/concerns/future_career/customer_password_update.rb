# frozen_string_literal: true

module FutureCareer
  # This exception belongs only to the authenticated Store customer update.
  # Do not relax the shared check used by other actions, including account erasure.
  module CustomerPasswordUpdate
    PASSWORD_ATTRIBUTES = %w[password password_confirmation current_password].freeze
    private_constant :PASSWORD_ATTRIBUTES

    def update
      attributes = permitted_params
      return super unless attributes[:password].present?

      # with_lock reloads before yielding. Concurrent first-password requests
      # must see the winner's digest and then require its current password.
      current_user.with_lock do
        @future_career_first_password_update = current_user.password_digest.blank? &&
          !(current_user.respond_to?(:locked?) && current_user.locked?) &&
          (attributes.keys.map(&:to_s) - PASSWORD_ATTRIBUTES).empty?

        return render_errors(current_user.errors) unless future_career_password_valid?(attributes)

        super
      ensure
        @future_career_first_password_update = false
      end
    end

    private

    def valid_current_password?
      @future_career_first_password_update || super
    end

    def future_career_password_valid?(attributes)
      password = attributes[:password]
      confirmation = attributes[:password_confirmation]
      current_user.errors.clear
      unless password.is_a?(String) && password.length >= 10
        current_user.errors.add(:password, :too_short, count: 10)
      end
      unless confirmation.is_a?(String) && confirmation == password
        current_user.errors.add(:password_confirmation, :confirmation, attribute: 'Password')
      end
      current_user.errors.empty?
    end
  end
end
