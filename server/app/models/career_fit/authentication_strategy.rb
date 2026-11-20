# frozen_string_literal: true

require 'jwt'
require 'openssl'

module CareerFit
  # Exchanges a short-lived, server-signed assertion for an existing Customer.
  # Account creation and Magic Link / Google validation belong to Nuxt.
  class AuthenticationStrategy < Spree::Authentication::Strategies::BaseStrategy
    MAX_LIFETIME = 60
    CLOCK_SKEW = 5
    REQUIRED_CLAIMS = %w[iss aud sub iat exp jti purpose customer_id email email_verified auth_time].freeze
    SUBJECT = /\Auser:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    CUSTOMER_ID = /\Acust_[A-Za-z0-9]+\z/

    def provider
      'career_fit'
    end

    def authenticate
      token = params[:token]
      return reject('missing_token') unless token.is_a?(String) && token.bytesize.between?(1, 8192)

      claims, header = JWT.decode(
        token, public_key, true,
        algorithms: ['RS256'],
        iss: ENV.fetch('CAREER_FIT_ASSERTION_ISSUER', 'career-fit-auth'),
        aud: ENV.fetch('CAREER_FIT_ASSERTION_AUDIENCE', 'spree-career-fit-auth'),
        verify_iss: true, verify_aud: true, verify_expiration: true,
        required_claims: REQUIRED_CLAIMS
      )
      return reject('invalid_claims') unless valid_claims?(claims, header)

      customer = Spree.customer_class.find_by_prefix_id(claims['customer_id'])
      return reject('customer_mismatch') unless customer && customer.email.to_s.strip.downcase == claims['email']
      return reject('customer_unavailable') if customer.locked? || customer.anonymized?

      success(customer)
    rescue JWT::DecodeError => error
      Rails.logger.warn("career_fit.authentication.rejected error=#{error.class.name}")
      failure(I18n.t('spree.api.unauthorized'))
    rescue KeyError, OpenSSL::PKey::PKeyError, ArgumentError => error
      # Never log assertion contents, email addresses or key material.
      Rails.logger.error("career_fit.authentication.configuration_error error=#{error.class.name}")
      failure(I18n.t('spree.api.unauthorized'))
    end

    private

    def public_key
      key = OpenSSL::PKey::RSA.new(ENV.fetch('CAREER_FIT_ASSERTION_PUBLIC_KEY').gsub('\\n', "\n"))
      raise ArgumentError, 'A public RSA key of at least 2048 bits is required' if key.private? || key.n.num_bits < 2048

      key
    end

    def valid_claims?(claims, header)
      now = Time.now.to_i
      issued_at = claims['iat']
      expires_at = claims['exp']
      auth_time = claims['auth_time']
      email = claims['email']
      customer_id = claims['customer_id']

      header['typ'] == 'JWT' &&
        header['kid'] == ENV.fetch('CAREER_FIT_ASSERTION_KEY_ID', 'career-fit-v1') &&
        claims['purpose'] == 'spree_auth_exchange' &&
        claims['email_verified'] == true &&
        claims['sub'].is_a?(String) && SUBJECT.match?(claims['sub']) &&
        claims['jti'].is_a?(String) && claims['jti'].length.between?(16, 128) &&
        customer_id.is_a?(String) && customer_id.length <= 32 && CUSTOMER_ID.match?(customer_id) &&
        email.is_a?(String) && email.length.between?(3, 128) && email == email.strip.downcase &&
        issued_at.is_a?(Integer) && expires_at.is_a?(Integer) && auth_time.is_a?(Integer) &&
        issued_at.positive? && issued_at <= now + CLOCK_SKEW &&
        expires_at > now && expires_at > issued_at && expires_at - issued_at <= MAX_LIFETIME &&
        auth_time.positive? && auth_time <= issued_at + CLOCK_SKEW
    end

    def reject(reason)
      Rails.logger.warn("career_fit.authentication.rejected reason=#{reason}")
      failure(I18n.t('spree.api.unauthorized'))
    end
  end
end
