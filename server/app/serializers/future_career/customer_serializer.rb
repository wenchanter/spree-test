# frozen_string_literal: true

module FutureCareer
  class CustomerSerializer < Spree::Api::V3::CustomerSerializer
    typelize has_password: :boolean

    attribute :has_password do |customer|
      customer.password_digest.present?
    end
  end
end
