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

    private

    def default_logger
      logger = Logger.new($stderr)
      logger.progname = 'AwsAdvancedRubyDriverWrapper'
      logger.level = Logger::INFO
      logger
    end
  end

  # Include this module in any class that needs logging.
  # Provides a private `logger` method that delegates to the module-level logger.
  module Logging
    private

    def logger
      AwsAdvancedRubyDriverWrapper.logger
    end
  end
end
