# frozen_string_literal: true

# Isolated unit tests: actual Spree BaseStrategy + JWT gem, no Rails boot or database.
require 'bundler/setup'
require 'minitest/autorun'
require 'stringio'
require 'logger'
require 'base64'
require 'json'
require 'i18n'
require 'spree/service_module'
require File.join(Gem::Specification.find_by_name('spree_core').full_gem_path,
                  'app/models/spree/authentication/strategies/base_strategy')
require_relative '../app/models/future_career/authentication_strategy'

I18n.enforce_available_locales = false
I18n.backend.store_translations(:en, spree: { api: { unauthorized: 'Unauthorized' } })

module Rails
  class << self
    attr_accessor :logger
  end
end

module Spree
  class << self
    attr_accessor :customer_class
  end
end

class FutureCareerAuthenticationTest < Minitest::Test
  KEY = OpenSSL::PKey::RSA.generate(2048)
  CUSTOMER_ID = 'cust_TestCustomer'
  Customer = Struct.new(:email, :locked, :anonymized) do
    def locked? = locked
    def anonymized? = anonymized
  end
  class Customers
    class << self
      attr_accessor :record, :lookups

      def find_by_prefix_id(id)
        self.lookups += 1
        record if id == CUSTOMER_ID
      end
    end
  end

  def setup
    @previous_env = ENV.to_h.select { |key, _| key.start_with?('FUTURE_CAREER_ASSERTION_') }
    ENV['FUTURE_CAREER_ASSERTION_PUBLIC_KEY'] = KEY.public_key.to_pem
    ENV['FUTURE_CAREER_ASSERTION_KEY_ID'] = 'test-key'
    ENV['FUTURE_CAREER_ASSERTION_ISSUER'] = 'future-career-auth'
    ENV['FUTURE_CAREER_ASSERTION_AUDIENCE'] = 'spree-future-career-auth'
    @logs = StringIO.new
    Rails.logger = Logger.new(@logs)
    Spree.customer_class = Customers
    Customers.record = Customer.new('Test@Example.com', false, false)
    Customers.lookups = 0
    now = Time.now.to_i
    @claims = {
      'iss' => 'future-career-auth', 'aud' => 'spree-future-career-auth',
      'sub' => 'user:00000000-0000-4000-8000-000000000001',
      'iat' => now, 'exp' => now + 60, 'auth_time' => now,
      'jti' => 'a' * 32, 'purpose' => 'spree_auth_exchange',
      'customer_id' => CUSTOMER_ID, 'email' => 'test@example.com', 'email_verified' => true
    }
    @headers = { typ: 'JWT', kid: 'test-key' }
  end

  def teardown
    ENV.keys.grep(/\AFUTURE_CAREER_ASSERTION_/).each { |key| ENV.delete(key) }
    @previous_env.each { |key, value| ENV[key] = value }
  end

  def sign_claims
    # Sign directly so malformed-claim tests reach the verifier; JWT.encode rejects them first.
    segments = [JSON.generate(@headers.merge(alg: 'RS256')), JSON.generate(@claims)]
      .map { |part| Base64.urlsafe_encode64(part, padding: false) }.join('.')
    segments + '.' + Base64.urlsafe_encode64(KEY.sign('SHA256', segments), padding: false)
  end

  def exchange(token = sign_claims)
    FutureCareer::AuthenticationStrategy.new(params: { token: token }, request_env: {}).authenticate
  end

  def test_returns_existing_customer_and_preserves_native_strategy_result
    result = exchange
    assert result.success?
    assert_same Customers.record, result.value
    assert_equal 1, Customers.lookups
  end

  def test_literal_newline_public_key_configuration
    ENV['FUTURE_CAREER_ASSERTION_PUBLIC_KEY'] = KEY.public_key.to_pem.gsub("\n", '\\n')
    assert exchange.success?
  end

  {
    'wrong_issuer' => ['iss', 'untrusted'],
    'wrong_audience' => ['aud', 'other-api'],
    'email_link_purpose' => ['purpose', 'login'],
    'unverified_email' => ['email_verified', false],
    'string_verified_flag' => ['email_verified', 'true'],
    'invalid_subject' => ['sub', 'user:invalid'],
    'admin_identifier' => ['customer_id', 'admin_TestCustomer'],
    'oversized_customer_id' => ['customer_id', 'cust_' + 'x' * 28],
    'non_string_customer_id' => ['customer_id', 1],
    'email_array' => ['email', ['test@example.com']],
    'uncanonical_email' => ['email', 'TEST@example.com'],
    'missing_entropy' => ['jti', 'short'],
    'string_expiry' => ['exp', 'invalid'],
    'float_issued_at' => ['iat', 1.5],
    'string_auth_time' => ['auth_time', 'invalid']
  }.each do |name, (claim, value)|
    define_method("test_rejects_#{name}_before_customer_lookup") do
      @claims[claim] = value
      refute exchange.success?
      assert_equal 0, Customers.lookups
    end
  end

  FutureCareer::AuthenticationStrategy::REQUIRED_CLAIMS.each do |claim|
    define_method("test_requires_#{claim}") do
      @claims.delete(claim)
      refute exchange.success?
      assert_equal 0, Customers.lookups
    end
  end

  def test_rejects_expired_assertion
    @claims['iat'] -= 70
    @claims['exp'] -= 70
    refute exchange.success?
  end

  def test_rejects_future_issued_assertion
    @claims['iat'] += 120
    @claims['exp'] += 120
    refute exchange.success?
  end

  def test_rejects_long_lifetime
    @claims['exp'] += 1
    refute exchange.success?
  end

  def test_rejects_future_authentication
    @claims['auth_time'] += 120
    refute exchange.success?
  end

  def test_rejects_untrusted_signing_key
    refute exchange(JWT.encode(@claims, OpenSSL::PKey::RSA.generate(2048), 'RS256', @headers)).success?
  end

  def test_rejects_hmac_and_unsigned_assertions
    refute exchange(JWT.encode(@claims, KEY.public_key.to_pem, 'HS256', @headers)).success?
    refute exchange(JWT.encode(@claims, nil, 'none', @headers)).success?
  end

  def test_rejects_wrong_header
    @headers[:kid] = 'untrusted-key'
    refute exchange.success?
    @headers = { typ: 'other', kid: 'test-key' }
    refute exchange.success?
  end

  def test_rejects_malformed_missing_and_oversized_tokens
    [nil, [], {}, 'invalid', 'x' * 8193].each { |token| refute exchange(token).success? }
    assert_equal 0, Customers.lookups
  end

  def test_missing_customer_and_different_email_fail_without_creation
    @claims['customer_id'] = 'cust_Unknown'
    refute exchange.success?
    @claims['customer_id'] = CUSTOMER_ID
    @claims['email'] = 'other@example.com'
    refute exchange.success?
  end

  def test_locked_and_anonymized_customers_are_rejected
    Customers.record.locked = true
    refute exchange.success?
    Customers.record.locked = false
    Customers.record.anonymized = true
    refute exchange.success?
  end

  def test_configuration_fails_closed_without_logging_secrets
    token = JWT.encode(@claims, KEY, 'RS256', @headers)
    ENV.delete('FUTURE_CAREER_ASSERTION_PUBLIC_KEY')
    refute exchange(token).success?
    ENV['FUTURE_CAREER_ASSERTION_PUBLIC_KEY'] = KEY.to_pem
    refute exchange(token).success?
    ENV['FUTURE_CAREER_ASSERTION_PUBLIC_KEY'] = 'not-a-public-key'
    refute exchange(token).success?
    ENV['FUTURE_CAREER_ASSERTION_PUBLIC_KEY'] = OpenSSL::PKey::RSA.generate(1024).public_key.to_pem
    refute exchange(token).success?
    refute_includes @logs.string, token
    refute_includes @logs.string, 'test@example.com'
    refute_includes @logs.string, 'PRIVATE KEY'
  end
end
