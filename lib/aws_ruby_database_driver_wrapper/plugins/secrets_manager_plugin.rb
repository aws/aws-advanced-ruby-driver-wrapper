# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require 'concurrent'
require_relative '../errors'
require_relative '../logging'
require_relative '../property_definition'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    class SecretsManagerPlugin
      include Logging

      SUBSCRIBED_METHODS = Set['connect', 'internal_connect'].freeze
      SECRETS_MANAGER_CACHE_NAME = :secrets_manager
      MIN_EXPIRATION_SEC = 300
      SYNC_FETCH_TIMEOUT_SEC = 60
      SECRETS_ARN_PATTERN = %r{\Aarn:aws:secretsmanager:(?<region>[^:\n]+):[^:\n]*:(?:[^:/\n]*[:/])?}
      MAX_RETRY_DELAY_SEC = 8

      SecretEntry = Data.define(:username, :password, :expires_at) do
        def expired?(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
          expires_at && now >= expires_at
        end
      end

      @pending_refreshes = Concurrent::Map.new

      class << self
        attr_reader :pending_refreshes

        def clear_cache(storage_service)
          storage_service.clear(SECRETS_MANAGER_CACHE_NAME)
        end
      end

      attr_reader :subscribed_methods

      def initialize(service_container, props = ::Concurrent::Map.new)
        ensure_sdk!
        @service_container = service_container
        @wrapper_props = props
        @credentials_provider = PropertyDefinition::SECRET_CREDENTIALS_PROVIDER.get(props) ||
                                Aws::CredentialProviderChain.new.resolve
        @secret_id = PropertyDefinition::SECRET_ID.get(props)
        raise Errors::SecretsManagerAuthError, 'secret_id is required' unless @secret_id

        @region = resolve_region(props)
        unless @region
          raise Errors::SecretsManagerAuthError,
                'Unable to determine region; set :secret_region or use a Secrets Manager ARN'
        end

        @username_key = PropertyDefinition::SECRET_USERNAME_KEY.get_string(props)
        @password_key = PropertyDefinition::SECRET_PASSWORD_KEY.get_string(props)
        @expiration_sec = resolve_expiration(props)
        @cache_key = "#{@secret_id}:#{@region}"
        @rotation_retry_timeout_sec = PropertyDefinition::SECRET_ROTATION_RETRY_TIMEOUT_MS.get_int(props) / 1000.0
        @rotation_retry_base_delay_sec = PropertyDefinition::SECRET_ROTATION_RETRY_BASE_DELAY_MS.get_int(props) / 1000.0

        service_container.storage_service.register(SECRETS_MANAGER_CACHE_NAME, ttl: @expiration_sec)
        @subscribed_methods = SUBSCRIBED_METHODS
      end

      def connect(_host_info, driver_props, _is_initial_connection, pipeline_callable)
        secrets_connect(driver_props, pipeline_callable)
      end

      def internal_connect(_host_info, driver_props, _wrapper_override_props, _is_initial_connection, pipeline_callable)
        secrets_connect(driver_props, pipeline_callable)
      end

      private

      def secrets_connect(driver_props, pipeline_callable)
        secret_is_fresh = fetch_secret_and_report_if_fresh?(force: false)
        apply_secret(driver_props)

        begin
          return pipeline_callable.call
        rescue StandardError => e
          raise unless !secret_is_fresh && @service_container.dialect_service.login_error?(e)
        end

        # First forced refetch + retry
        fetch_secret_and_report_if_fresh?(force: true)
        apply_secret(driver_props)

        begin
          pipeline_callable.call
        rescue StandardError => e
          raise unless @rotation_retry_timeout_sec.positive? && @service_container.dialect_service.login_error?(e)

          rotation_retry(driver_props, pipeline_callable, e)
        end
      end

      # Retry loop for rotation window: poll GetSecretValue with exponential backoff
      # until AWSCURRENT is promoted or timeout expires.
      def rotation_retry(driver_props, pipeline_callable, last_error)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @rotation_retry_timeout_sec
        delay_sec = @rotation_retry_base_delay_sec

        logger.info("SecretsManagerPlugin: entering rotation retry loop (timeout=#{@rotation_retry_timeout_sec}s)")

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise last_error if remaining <= 0

          sleep_sec = [delay_sec, remaining].min
          sleep(sleep_sec)

          fetch_secret_and_report_if_fresh?(force: true)
          apply_secret(driver_props)

          begin
            return pipeline_callable.call
          rescue StandardError => e
            raise unless @service_container.dialect_service.login_error?(e)

            last_error = e
            delay_sec = [delay_sec * 2, MAX_RETRY_DELAY_SEC].min
          end
        end
      end

      # Returns true if credentials were freshly fetched from the service (suppresses login-error retry).
      def fetch_secret_and_report_if_fresh?(force:)
        entry = @service_container.storage_service.get(SECRETS_MANAGER_CACHE_NAME, @cache_key)

        if entry.nil? || force
          @secret = fetch_synchronously
          return !@secret.nil?
        end

        if entry.expired?
          logger.debug('SecretsManagerPlugin: serving stale credentials, refreshing in background')
          @secret = entry
          trigger_async_refresh
          return false
        end

        @secret = entry
        false
      end

      def fetch_synchronously
        future = trigger_async_refresh
        future.value!(SYNC_FETCH_TIMEOUT_SEC)
      rescue Concurrent::CancelledOperationError, Timeout::Error
        raise Errors::SecretsManagerAuthError,
              "Timed out fetching secret after #{SYNC_FETCH_TIMEOUT_SEC}s"
      end

      def trigger_async_refresh
        pending = self.class.pending_refreshes

        existing = pending[@cache_key]
        return existing if existing && !existing.resolved?

        future_candidate = Concurrent::Promises.delay_on(:io) { fetch_and_store_secret }
        stored = pending.put_if_absent(@cache_key, future_candidate)
        return stored if stored

        future_candidate.touch

        future_candidate.on_resolution! do |_fulfilled, _value, reason|
          pending.delete_pair(@cache_key, future_candidate)
          logger.debug("SecretsManagerPlugin: async refresh failed: #{reason}") if reason
        end

        future_candidate
      end

      def fetch_and_store_secret
        response = secrets_client.get_secret_value(secret_id: @secret_id)
        parsed = JSON.parse(response.secret_string)

        unless parsed.key?(@username_key) && parsed.key?(@password_key)
          raise Errors::SecretsManagerAuthError,
                "Secret JSON missing required keys: '#{@username_key}' and/or '#{@password_key}'"
        end

        entry = SecretEntry.new(
          username: parsed[@username_key],
          password: parsed[@password_key],
          expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + @expiration_sec
        )
        @service_container.storage_service.set(SECRETS_MANAGER_CACHE_NAME, @cache_key, entry)
        entry
      end

      def apply_secret(driver_props)
        raise Errors::SecretsManagerAuthError, 'Failed to fetch database credentials from AWS Secrets Manager' unless @secret

        user_key = @service_container.dialect_service.driver_dialect.user_property_key
        driver_props[user_key] = @secret.username
        driver_props[:password] = @secret.password
      end

      def secrets_client
        @secrets_client ||= begin
          opts = { region: @region, credentials: @credentials_provider }
          endpoint = PropertyDefinition::SECRET_ENDPOINT.get(@wrapper_props)
          opts[:endpoint] = endpoint if endpoint
          Aws::SecretsManager::Client.new(**opts)
        end
      end

      def resolve_region(props)
        explicit = PropertyDefinition::SECRET_REGION.get(props)
        return explicit if explicit

        match = SECRETS_ARN_PATTERN.match(@secret_id.to_s)
        match[:region] if match
      end

      def resolve_expiration(props)
        configured = PropertyDefinition::SECRET_EXPIRATION_SEC.get_int(props)
        if configured < MIN_EXPIRATION_SEC
          logger.warn("SecretsManagerPlugin: expiration #{configured}s below minimum #{MIN_EXPIRATION_SEC}s, clamping")
          MIN_EXPIRATION_SEC
        else
          configured
        end
      end

      def ensure_sdk!
        require 'aws-sdk-secretsmanager'
        require 'json'
      rescue LoadError
        raise LoadError,
              "The Secrets Manager plugin requires 'aws-sdk-secretsmanager'. " \
              "Add it to your Gemfile: gem 'aws-sdk-secretsmanager'"
      end
    end
  end
end
