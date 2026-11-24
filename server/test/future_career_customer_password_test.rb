# frozen_string_literal: true

# Real Rails/Spree controller, serializer, password policy and BCrypt. Customer
# persistence is replaced with a locked in-memory record; no database is touched.
require_relative '../config/environment'
require 'minitest/autorun'

class FutureCareerCustomerPasswordTest < Minitest::Test
  State = Struct.new(:digest, :mutex, :writes)

  class Customer
    include ActiveModel::Model
    include ActiveModel::SecurePassword
    attr_accessor :password_digest, :email, :first_name, :last_name, :phone,
                  :accepts_email_marketing, :consent_source, :locked
    attr_reader :state, :failed_attempts, :lock_count
    has_secure_password validations: false
    include Spree::PasswordPolicy

    def initialize(state = State.new(nil, Mutex.new, 0))
      @state = state
      @password_digest = state.digest
      @email = 'customer@example.test'
      @failed_attempts = 0
      @lock_count = 0
    end

    def with_lock
      state.mutex.synchronize do
        @lock_count += 1
        @password_digest = state.digest # Active Record with_lock reloads the row.
        yield
      end
    end

    def update(attributes)
      assign_attributes(attributes.to_h)
      return false unless valid?

      state.digest = password_digest
      state.writes += 1
      true
    end

    def password_digest_changed? = password_digest != state.digest
    def valid_password?(candidate) = password_digest.present? && authenticate(candidate).present?
    def locked? = !!locked
    def record_failed_attempt! = @failed_attempts += 1
    def reset_failed_attempts! = @failed_attempts = 0
    def prefixed_id = 'cust_PasswordTest'
    def full_name = nil
    def email_marketing_consent_updated_at = nil
    def total_available_store_credit(*) = 0
    def addresses = []
    def bill_address = nil
    def ship_address = nil
    def newsletter_subscriber(*) = nil
    def customer_groups = self
    def for_store(*) = []
  end

  class Controller < Spree::Api::V3::Store::CustomersController
    attr_reader :response_payload

    def initialize(customer, attributes)
      super()
      @customer = customer
      @_action_name = 'update'
      self.params = ActionController::Parameters.new(attributes)
    end

    def current_user = @customer
    def render(**payload) = @response_payload = payload

    protected

    def serialize_resource(customer)
      # Exercise the real registered serializer's account fields; unrelated
      # credit/address fields require SQL-backed associations.
      serializer = serializer_class.new(customer, params: serializer_params)
      serializer.define_singleton_method(:attributes) { super().slice(:id, :email, :has_password) }
      serializer.to_h
    end

    def serializer_params
      { store: Struct.new(:default_currency).new('USD'), currency: 'USD', includes: [] }
    end
  end

  PASSWORD = 'a-new-password-123'

  def update(customer, attributes = {})
    controller = Controller.new(customer, { password: PASSWORD, password_confirmation: PASSWORD }.merge(attributes))
    controller.update
    controller
  end

  def test_boot_registers_extension_once_and_only_on_customer_update_controller
    assert_equal FutureCareer::CustomerSerializer, Spree.api.customer_serializer
    2.times { Rails.application.reloader.prepare! }
    assert_equal 1, Spree::Api::V3::Store::CustomersController.ancestors.count(FutureCareer::CustomerPasswordUpdate)
    assert_equal Spree::Api::V3::CurrentPasswordConfirmation,
                 Spree::Api::V3::CurrentPasswordConfirmation.instance_method(:valid_current_password?).owner
  end

  def test_serializer_reflects_actual_digest_without_exposing_it
    customer = Customer.new
    controller = Controller.new(customer, {})
    controller.show
    data = controller.response_payload.fetch(:json)
    assert_equal false, data.fetch('has_password')
    refute data.key?('password_digest')
    update(customer)
    controller.show
    assert_equal true, controller.response_payload.fetch(:json).fetch('has_password')
  end

  def test_first_password_needs_no_current_password
    customer = Customer.new
    controller = update(customer)
    assert_equal true, controller.response_payload.fetch(:json).fetch('has_password')
    assert customer.valid_password?(PASSWORD)
    assert_equal 1, customer.lock_count
    assert_equal 1, customer.state.writes
  end

  def test_missing_confirmation_and_short_or_mismatched_passwords_do_not_save
    [{ password_confirmation: nil }, { password: 'short', password_confirmation: 'short' },
     { password_confirmation: 'different-value' }].each do |attributes|
      customer = Customer.new
      controller = update(customer, attributes)
      assert_equal :unprocessable_content, controller.response_payload.fetch(:status)
      assert_nil customer.state.digest
      assert_equal 0, customer.state.writes
    end
  end

  def test_model_keeps_stricter_configured_minimum
    previous = Spree::Config[:minimum_password_length]
    Spree::Config[:minimum_password_length] = 30
    customer = Customer.new
    controller = update(customer)
    assert_equal :unprocessable_content, controller.response_payload.fetch(:status)
    assert_equal 0, customer.state.writes
  ensure
    Spree::Config[:minimum_password_length] = previous
  end

  def test_first_password_cannot_also_change_email_or_profile
    [{ email: 'other@example.test' }, { first_name: 'Different' }].each do |attributes|
      customer = Customer.new
      controller = update(customer, attributes)
      assert_equal 'current_password_invalid', controller.response_payload.fetch(:json).dig(:error, :code)
      assert_equal 0, customer.state.writes
      assert_equal 'customer@example.test', customer.email
    end
  end

  def test_existing_password_still_requires_old_password_and_counts_failures
    customer = Customer.new
    update(customer)
    [nil, 'wrong-password'].each do |old_password|
      controller = update(customer, current_password: old_password, password: 'replacement-password', password_confirmation: 'replacement-password')
      assert_equal 'current_password_invalid', controller.response_payload.fetch(:json).dig(:error, :code)
      assert customer.valid_password?(PASSWORD)
    end
    assert_equal 1, customer.failed_attempts
    assert_equal 1, customer.state.writes
  end

  def test_existing_password_changes_with_correct_old_password
    customer = Customer.new
    update(customer)
    controller = update(customer, current_password: PASSWORD, password: 'replacement-password', password_confirmation: 'replacement-password')
    assert_equal true, controller.response_payload.fetch(:json).fetch('has_password')
    assert customer.valid_password?('replacement-password')
    refute customer.valid_password?(PASSWORD)
    assert_equal 2, customer.state.writes
  end

  def test_locked_customer_cannot_use_existing_password
    customer = Customer.new
    update(customer)
    customer.locked = true
    controller = update(customer, current_password: PASSWORD)
    assert_equal 'current_password_invalid', controller.response_payload.fetch(:json).dig(:error, :code)
    assert_equal 1, customer.state.writes
  end

  def test_locked_customer_cannot_set_first_password
    customer = Customer.new
    customer.locked = true
    controller = update(customer)
    assert_equal 'current_password_invalid', controller.response_payload.fetch(:json).dig(:error, :code)
    assert_nil customer.state.digest
  end

  def test_email_only_update_keeps_upstream_current_password_check
    customer = Customer.new
    controller = Controller.new(customer, email: 'other@example.test')
    controller.update
    assert_equal 'current_password_invalid', controller.response_payload.fetch(:json).dig(:error, :code)
    assert_equal 'customer@example.test', customer.email
  end

  def test_concurrent_first_password_requests_only_write_once
    state = State.new(nil, Mutex.new, 0)
    customers = [Customer.new(state), Customer.new(state)]
    responses = customers.map.with_index do |customer, index|
      Thread.new { update(customer, password: "password-from-request-#{index}", password_confirmation: "password-from-request-#{index}").response_payload }
    end.map(&:value)
    assert_equal 1, state.writes
    assert_equal 1, responses.count { |result| result[:json]['has_password'] == true }
    assert_equal 1, responses.count { |result| result[:json].dig(:error, :code) == 'current_password_invalid' }
  end
end
