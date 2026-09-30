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

require 'digest'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module AwsCredentialsUtils
      module_function

      # Stands in for the identity when a provider resolves to no credentials.
      NO_CREDENTIALS = 'none'
      IDENTITY_LENGTH = 16

      # A short, stable identifier for the AWS credentials a provider currently resolves to, for
      # use in cache keys: two providers that resolve to the same access key share it, and a
      # provider that refreshes to a new access key (a new assumed-role session, for example) gets
      # a new one. It is derived from the access key id alone, which is hashed so that not even
      # that appears in a cache key. The secret key is never read.
      #
      # @param credentials_provider [#credentials, Aws::Credentials, nil]
      # @return [String]
      def identity(credentials_provider)
        credentials = credentials_provider.respond_to?(:credentials) ? credentials_provider.credentials : credentials_provider
        access_key_id = credentials.respond_to?(:access_key_id) ? credentials.access_key_id : nil
        return NO_CREDENTIALS if access_key_id.nil? || access_key_id.empty?

        Digest::SHA256.hexdigest(access_key_id)[0, IDENTITY_LENGTH]
      end
    end
  end
end
