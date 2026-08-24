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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # Redaction helpers shared by the audit logger, the error context builder, and the
      # kms_encryption error classes. Every method returns nil when given nil so that callers
      # can decide how to render a missing value.
      module Sanitizer
        # Matches "password=...", "secret=...", "key=...", "token=..." assignments.
        SENSITIVE_ASSIGNMENT_PATTERN = /(password|secret|key|token)=[^\s]+/i
        # Same as above, plus "credential=...", and stops at commas and closing braces so that
        # it works on rendered hashes.
        CREDENTIAL_ASSIGNMENT_PATTERN = /(password|secret|key|token|credential)=[^\s,}]+/i
        KMS_ARN_PATTERN = %r{arn:aws:kms:[^:]+:[^:]+:key/[a-f0-9-]+}i
        URL_PASSWORD_PATTERN = /[?&]password=[^&]*/i
        URL_PWD_PATTERN = /[?&]pwd=[^&]*/i
        URL_USER_INFO_PATTERN = %r{://[^:/@]+:[^@]+@}
        SQL_STRING_LITERAL_PATTERN = /'[^']*'/
        SQL_NUMERIC_LITERAL_PATTERN = /\b\d+\b/

        MAX_NAME_LENGTH = 50
        MAX_DESCRIPTION_LENGTH = 100
        MAX_CONFIG_DETAILS_LENGTH = 150
        MAX_ERROR_MESSAGE_LENGTH = 200
        MAX_SQL_LENGTH = 100

        module_function

        # Masks the account and region of a KMS key ARN, keeping only the trailing key id.
        # @param value [String, nil]
        # @return [String, nil]
        def arn(value)
          return nil if value.nil?

          last_slash = value.rindex('/')
          return 'arn:aws:kms:***:***:key/***' if last_slash.nil? || last_slash.zero? || last_slash == value.length - 1

          "arn:aws:kms:***:***:key/#{value[(last_slash + 1)..]}"
        end

        # Keeps the first and last four characters of a key id, masking the middle.
        # @param value [String, nil]
        # @return [String, nil]
        def key_id(value)
          return nil if value.nil?

          str = value.to_s
          str.length > 8 ? "#{str[0, 4]}***#{str[-4..]}" : '***'
        end

        # @param value [String, nil]
        # @return [String, nil]
        def table_name(value)
          truncate(value, MAX_NAME_LENGTH)
        end

        # @param value [String, nil]
        # @return [String, nil]
        def column_name(value)
          truncate(value, MAX_NAME_LENGTH)
        end

        # @param value [String, nil]
        # @return [String, nil]
        def description(value)
          return nil if value.nil?

          truncate(value.gsub(SENSITIVE_ASSIGNMENT_PATTERN, '\1=***'), MAX_DESCRIPTION_LENGTH)
        end

        # @param value [String, nil]
        # @return [String, nil]
        def error_message(value)
          return nil if value.nil?

          masked = value.gsub(SENSITIVE_ASSIGNMENT_PATTERN, '\1=***')
                        .gsub(KMS_ARN_PATTERN, 'arn:aws:kms:***:***:key/***')
          truncate(masked, MAX_ERROR_MESSAGE_LENGTH)
        end

        # @param value [String, nil]
        # @return [String, nil]
        def config_details(value)
          return nil if value.nil?

          masked = value.gsub(CREDENTIAL_ASSIGNMENT_PATTERN, '\1=***')
                        .gsub(KMS_ARN_PATTERN, 'arn:aws:kms:***:***:key/***')
          truncate(masked, MAX_CONFIG_DETAILS_LENGTH)
        end

        # Masks credentials embedded in a connection URL, both as query parameters and as user info.
        # @param value [String, nil]
        # @return [String, nil]
        def connection_url(value)
          return nil if value.nil?

          value.gsub(URL_PASSWORD_PATTERN, '?password=***')
               .gsub(URL_PWD_PATTERN, '?pwd=***')
               .gsub(URL_USER_INFO_PATTERN, '://***:***@')
        end

        # Replaces string and numeric literals so that SQL can be logged without leaking values.
        # @param value [String, nil]
        # @return [String, nil]
        def sql(value)
          return nil if value.nil?

          masked = value.gsub(SQL_STRING_LITERAL_PATTERN, "'***'")
                        .gsub(SQL_NUMERIC_LITERAL_PATTERN, '***')
          truncate(masked, MAX_SQL_LENGTH)
        end

        # @param value [String, nil]
        # @param limit [Integer]
        # @return [String, nil]
        def truncate(value, limit)
          return nil if value.nil?

          str = value.to_s
          str.length > limit ? "#{str[0, limit - 3]}..." : str
        end
      end
    end
  end
end
