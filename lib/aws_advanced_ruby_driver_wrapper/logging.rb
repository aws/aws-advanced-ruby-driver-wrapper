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

require 'logger'

module AwsAdvancedRubyDriverWrapper
  # The value substituted for any redacted (sensitive) property value.
  REDACTED = '***'

  # Sensitive property markers. A property key is treated as secret when it
  # equals one of these or contains one as a substring.
  SECRET_PROPERTY_KEYS = %w[password token secret credential].freeze

  class << self
    # Returns the logger used by the wrapper. Defaults to a Logger writing to $stderr.
    # Users can replace this with any object that responds to the standard Logger methods
    # (debug, info, warn, error, fatal).
    #
    # @example Setting a custom logger
    #   AwsAdvancedRubyDriverWrapper.logger = Logger.new('wrapper.log')
    #
    # @example Using Rails logger
    #   AwsAdvancedRubyDriverWrapper.logger = Rails.logger
    #
    # @return [Logger]
    attr_writer :logger

    def logger
      @logger ||= default_logger
    end

    # Returns a copy of the given properties with the values of any sensitive
    # keys (password, token, secret, credential, or keys containing those
    # substrings) replaced with a redaction marker. The original collection is
    # never mutated. Use this whenever properties may be written to logs.
    #
    # Accepts a Hash, Concurrent::Map, or any object responding to #each_pair or
    # #each_key/#[]. Returns a plain Hash so it is always safe to interpolate.
    #
    # @example
    #   logger.debug("connecting with #{AwsAdvancedRubyDriverWrapper.mask_properties(props)}")
    #
    # @param props [#each_pair, #to_h, nil] the properties to mask
    # @return [Hash] a new hash with sensitive values redacted
    def mask_properties(props)
      return {} if props.nil?

      pairs =
        if props.respond_to?(:each_pair)
          props.each_pair
        elsif props.respond_to?(:to_h)
          props.to_h
        else
          return {}
        end

      pairs.each_with_object({}) do |(key, value), masked|
        masked[key] = secret_key?(key) ? REDACTED : value
      end
    end

    # @return [Boolean] whether the given property key is considered sensitive
    def secret_key?(key)
      normalized = key.to_s.downcase
      SECRET_PROPERTY_KEYS.any? { |marker| normalized.include?(marker) }
    end

    private

    def default_logger
      logger = Logger.new($stderr)
      logger.progname = 'AwsAdvancedRubyDriverWrapper'
      logger.level = Logger::INFO
      logger
    end
  end

  # Include this module in any class that needs logging.
  # Provides a private `logger` method that delegates to the module-level logger,
  # and a private `mask_properties` helper for redacting sensitive values.
  module Logging
    private

    def logger
      AwsAdvancedRubyDriverWrapper.logger
    end

    # @see AwsAdvancedRubyDriverWrapper.mask_properties
    def mask_properties(props)
      AwsAdvancedRubyDriverWrapper.mask_properties(props)
    end
  end
end
