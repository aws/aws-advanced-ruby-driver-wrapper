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
require_relative '../utils/aws_credentials_utils'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    class SecretsManagerPlugin
      include Logging

      SUBSCRIBED_METHODS = Set['connect', 'internal_connect'].freeze
      SECRETS_MANAGER_CACHE_NAME = :secrets_manager
      MIN_EXPIRATION_SEC = 300
      SYNC_FETCH_TIMEOUT_SEC = 60
      # The partition segment of an ARN varies across AWS partitions, so match any of them.
      SECRETS_ARN_PATTERN = %r{\Aarn:aws(?:-[a-z]+)*:secretsmanager:(?<region>[^:\n]+):[^:\n]*:(?:[^:/\n]*[:/])?}
      MAX_RETRY_DELAY_SEC = 8

      # The maximum time a fetched secret stays in the shared cache, measured from when it was
      # fetched (the cache anchors expiry at store time and does not renew on read). Until its
      # logical expiration (@expiration_sec, default 14.5 min) the entry is served fresh;
      # between logical expiration and this disposal time it is served stale while a background
      # refresh runs (SWR); after this it is physically removed and the next use re-fetches from
      # Secrets Manager. This is the hard cap on how long a cached secret can live.
      SECRET_CACHE_DISPOSAL_SEC = 20 * 60

      # The window reserved between logical expiration and physical disposal for a background
      # refresh to complete. The logical expiration is clamped so that at least this much time
      # remains for stale-while-revalidate. Sized to the synchronous fetch timeout so a refresh
      # has a full fetch's worth of time to land.
      SWR_REVALIDATION_BUDGET_SEC = SYNC_FETCH_TIMEOUT_SEC

      # The largest logical expiration we allow, leaving room for the SWR refresh window.
      MAX_EXPIRATION_SEC = SECRET_CACHE_DISPOSAL_SEC - SWR_REVALIDATION_BUDGET_SEC

      SecretEntry = Data.define(:username, :password, :expires_at) do
        def expired?(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
          expires_at && now >= expires_at
        end

        # Redact the password so the secret is never exposed if an instance is
        # logged, interpolated, or rendered in a backtrace.
        def inspect
          "#<data SecretEntry username=#{username.inspect}, " \
            "password=#{AwsAdvancedRubyDriverWrapper::REDACTED.inspect}, expires_at=#{expires_at.inspect}>"
        end
        alias_method :to_s, :inspect

        # `pp` / PrettyPrint does not call #inspect; route them through the
        # redacted representation so `pp entry` cannot leak the password.
        def pretty_print(pp)
          pp.text(inspect)
        end
      end

      @pending_refreshes = Concurrent::Map.new

      class << self
        attr_reader :pending_refreshes

        def clear_cache(storage_service)
          storage_service.clear(SECRETS_MANAGER_CACHE_NAME)
        end

        # Forgets fetches inherited by a forked child. A fetch running at fork time lost its thread,
        # so its future never resolves and would otherwise be returned to every later fetch for its key.
        def release_pending_refreshes_after_fork
          @pending_refreshes.clear
        end

        # The secret's value depends on which secret is read, from which region and endpoint, and
        # with which AWS credentials, so all of them are part of the key. Connections that differ in
        # any of them neither share a cached secret nor wait on each other's fetch.
        #
        # @param endpoint [String, nil] the custom Secrets Manager endpoint, if any
        # @param credentials_identity [String] from {Utils::AwsCredentialsUtils.identity}
        def cache_key(secret_id, region, endpoint, credentials_identity)
          "#{secret_id}:#{region}:#{endpoint}:#{credentials_identity}"
        end
      end

      attr_reader :subscribed_methods

      def initialize(service_container, props = ::Concurrent::Map.new)
        ensure_sdk!
        @service_container = service_container
        @wrapper_props = props
        @credentials_provider = PropertyDefinition::AWS_CREDENTIALS_PROVIDER.get(props) ||
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
        @endpoint = PropertyDefinition::SECRET_ENDPOINT.get(props)
        @rotation_retry_timeout_sec = PropertyDefinition::SECRET_ROTATION_RETRY_TIMEOUT_SEC.get_float(props)
        @rotation_retry_base_delay_sec = PropertyDefinition::SECRET_ROTATION_RETRY_BASE_DELAY_SEC.get_float(props)

        service_container.storage_service.register(
          SECRETS_MANAGER_CACHE_NAME,
          ttl: SECRET_CACHE_DISPOSAL_SEC
        )

        @subscribed_methods = SUBSCRIBED_METHODS
      end

      def connect(_host_info, driver_props, _is_initial_connection, pipeline_callable)
        secrets_connect(driver_props, pipeline_callable)
      end

      def internal_connect(_host_info, driver_props, _, _is_initial_connection, pipeline_callable)
        secrets_connect(driver_props, pipeline_callable)
      end

      private

      def secrets_connect(driver_props, pipeline_callable)
        if @rotation_retry_timeout_sec.positive?
          connect_with_rotation_budget(driver_props, pipeline_callable)
        else
          connect_with_single_retry(driver_props, pipeline_callable)
        end
      end

      # Default behavior (budget disabled): at most one forced re-fetch, and only when
      # the *cached* secret failed to log in.
      def connect_with_single_retry(driver_props, pipeline_callable)
        secret_is_fresh = fetch_secret_and_report_if_fresh?(force: false)
        apply_secret(driver_props)

        begin
          return pipeline_callable.call
        rescue StandardError => e
          raise unless !secret_is_fresh && @service_container.dialect_service.login_error?(e)
        end

        fetch_secret_and_report_if_fresh?(force: true)
        apply_secret(driver_props)
        pipeline_callable.call
      end

      # Budgeted behavior: force a re-fetch + reconnect with capped exponential backoff
      # until login succeeds or the time budget is exhausted. Bridges the rotation window
      # including the cold-cache first connection, and tolerates transient fetch failures.
      def connect_with_rotation_budget(driver_props, pipeline_callable)
        deadline  = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @rotation_retry_timeout_sec
        delay_sec = @rotation_retry_base_delay_sec
        last_login_error = nil
        attempt = 0

        loop do
          attempt += 1

          begin
            # Attempt 1 may use the cache; every later attempt forces a re-fetch to pick up
            # a version promoted in the meantime.
            fetch_secret_and_report_if_fresh?(force: attempt > 1)
          rescue StandardError => e
            raise e if last_login_error.nil?

            # Otherwise a transient Secrets Manager failure must not consume the budget;
            # keep the login error as the reported cause and try again.
            logger.debug("SecretsManagerPlugin: re-fetch failed mid-retry (#{e.class}: #{e.message}); keeping login error")
          else
            apply_secret(driver_props)
            begin
              connection = pipeline_callable.call
              logger.info("SecretsManagerPlugin: connection succeeded on attempt #{attempt}") if attempt > 1
              return connection
            rescue StandardError => e
              # Not a credentials problem -> re-fetching would not help.
              raise unless @service_container.dialect_service.login_error?(e)

              last_login_error = e
            end
          end

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            logger.info("SecretsManagerPlugin: rotation retry budget exhausted after #{attempt} attempt(s)")
            raise last_login_error
          end

          sleep([delay_sec, remaining].min)
          delay_sec = [delay_sec * 2, MAX_RETRY_DELAY_SEC].min
        end
      end

      # Returns true if credentials were freshly fetched from the service (suppresses login-error retry).
      def fetch_secret_and_report_if_fresh?(force:)
        credentials = Utils::AwsCredentialsUtils.snapshot(@credentials_provider)
        cache_key = secret_cache_key(credentials)
        entry = cache_key && @service_container.storage_service.get(SECRETS_MANAGER_CACHE_NAME, cache_key)

        if entry.nil? || force
          @secret = fetch_synchronously(cache_key, credentials)
          return !@secret.nil?
        end

        if entry.expired?
          logger.debug('SecretsManagerPlugin: serving stale credentials, refreshing in background')
          @secret = entry
          trigger_async_refresh(cache_key, credentials)
          return false
        end

        @secret = entry
        false
      end

      # The cache key for a secret read with the given credentials snapshot. Built per fetch, so it
      # follows credentials that refresh to a new access key. Nil when there are no credentials:
      # without them there is nothing to tell one connection's secret from another's, so such a
      # connection neither reads nor writes the shared cache, and does not join another connection's
      # in-flight fetch.
      def secret_cache_key(credentials)
        return nil if credentials.nil?

        self.class.cache_key(@secret_id, @region, @endpoint, Utils::AwsCredentialsUtils.identity(credentials))
      end

      def fetch_synchronously(cache_key, credentials)
        future =
          if cache_key
            trigger_async_refresh(cache_key, credentials)
          else
            Concurrent::Promises.future_on(:io) { fetch_and_store_secret(nil, credentials) }
          end
        # value! returns nil instead of raising when the timeout elapses; a completed fetch always
        # returns an entry or raises.
        future.value!(SYNC_FETCH_TIMEOUT_SEC) || raise(Timeout::Error)
      rescue Concurrent::CancelledOperationError, Timeout::Error
        raise Errors::SecretsManagerAuthError,
              "Timed out fetching secret after #{SYNC_FETCH_TIMEOUT_SEC}s"
      end

      def trigger_async_refresh(cache_key, credentials)
        pending = self.class.pending_refreshes

        existing = pending[cache_key]
        return existing if existing && !existing.resolved?

        future_candidate = Concurrent::Promises.delay_on(:io) { fetch_and_store_secret(cache_key, credentials) }
        stored = pending.put_if_absent(cache_key, future_candidate)
        return stored if stored

        future_candidate.touch

        future_candidate.on_resolution! do |_fulfilled, _value, reason|
          pending.delete_pair(cache_key, future_candidate)
          logger.debug("SecretsManagerPlugin: async refresh failed: #{reason}") if reason
        end

        future_candidate
      end

      # Fetches the secret with the same credentials snapshot its cache key was built from and, when
      # there is a cache key, caches it.
      def fetch_and_store_secret(cache_key, credentials)
        response = build_secrets_client(credentials).get_secret_value(secret_id: @secret_id)
        parsed = parse_secret_string(response.secret_string)

        unless parsed.is_a?(Hash) && parsed.key?(@username_key) && parsed.key?(@password_key)
          raise Errors::SecretsManagerAuthError,
                "Secret JSON missing required keys: '#{@username_key}' and/or '#{@password_key}'"
        end

        entry = SecretEntry.new(
          username: parsed[@username_key],
          password: parsed[@password_key],
          expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + @expiration_sec
        )
        @service_container.storage_service.set(SECRETS_MANAGER_CACHE_NAME, cache_key, entry) if cache_key
        entry
      end

      # Parse the raw secret string as JSON. A plaintext (non-JSON) secret makes
      # +JSON.parse+ raise a +JSON::ParserError+. Catch that error and re-raise a
      # +SecretsManagerAuthError+ with a message that never includes the secret.
      def parse_secret_string(secret_string)
        JSON.parse(secret_string)
      rescue JSON::ParserError
        raise Errors::SecretsManagerAuthError,
              'The secret is not in the expected JSON format. Ensure the secret stored in AWS ' \
              'Secrets Manager is a JSON object containing the configured username and password keys.'
      end

      def apply_secret(driver_props)
        raise Errors::SecretsManagerAuthError, 'Failed to fetch database credentials from AWS Secrets Manager' unless @secret

        user_key = @service_container.dialect_service.driver_dialect.user_property_key
        driver_props[user_key] = @secret.username
        driver_props[:password] = @secret.password
      end

      # A client for one fetch, signing with the given credentials snapshot. Without a snapshot the
      # provider is passed as is, and the request fails for lack of credentials. Fetches only happen
      # on a cache miss or refresh, so building a client for each one costs little.
      def build_secrets_client(credentials)
        opts = { region: @region, credentials: credentials || @credentials_provider }
        opts[:endpoint] = @endpoint if @endpoint
        Aws::SecretsManager::Client.new(**opts)
      end

      def resolve_region(props)
        explicit = PropertyDefinition::SECRET_REGION.get(props)
        return explicit if explicit

        match = SECRETS_ARN_PATTERN.match(@secret_id.to_s)
        match[:region] if match
      end

      # The logical expiration must leave room for the stale-while-revalidate window: an entry is
      # physically removed SECRET_CACHE_DISPOSAL_SEC after it was fetched, so once it expires it can
      # only be served stale until then. Clamp it to the range [MIN_EXPIRATION_SEC, MAX_EXPIRATION_SEC],
      # where MAX_EXPIRATION_SEC reserves SWR_REVALIDATION_BUDGET_SEC before disposal for the refresh to complete.
      def resolve_expiration(props)
        configured = PropertyDefinition::SECRET_EXPIRATION_SEC.get_float(props)
        if configured < MIN_EXPIRATION_SEC
          logger.warn("SecretsManagerPlugin: expiration #{configured}s below minimum #{MIN_EXPIRATION_SEC}s, clamping")
          MIN_EXPIRATION_SEC
        elsif configured > MAX_EXPIRATION_SEC
          logger.warn("SecretsManagerPlugin: expiration #{configured}s exceeds the #{MAX_EXPIRATION_SEC}s maximum " \
                      "(leaving #{SWR_REVALIDATION_BUDGET_SEC}s before the #{SECRET_CACHE_DISPOSAL_SEC}s cache " \
                      'lifetime cap for stale-while-revalidate), clamping')
          MAX_EXPIRATION_SEC
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
