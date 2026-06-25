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

require 'uri'
require_relative 'rds_utils'
require_relative 'rds_url_type'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module IamAuthUtils
      module_function

      TokenEntry = Data.define(:token, :expires_at)

      EXPIRY_BUFFER_SEC = 60

      def parse_token_expiry(token)
        URI.decode_www_form(URI.parse("https://#{token}").query)
           .filter_map { |(key, value)| Integer(value, 10) if key.downcase == 'x-amz-expires' }
           .first
      rescue StandardError
        nil
      end

      def build_token_entry(token, fallback_expiry_sec)
        expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                     (parse_token_expiry(token) || fallback_expiry_sec) -
                     EXPIRY_BUFFER_SEC
        TokenEntry.new(token:, expires_at:)
      end

      def valid_entry?(entry)
        entry.is_a?(TokenEntry) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < entry.expires_at
      end

      def region_for(host:, props:, rds_type:, credentials_provider:, rds_client: nil)
        explicit = props[:iam_region]
        return explicit if explicit && !explicit.empty?

        return RdsUtils.rds_region(host) unless rds_type == RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER

        region_from_global_cluster(host, credentials_provider, rds_client: rds_client)
      end

      def region_from_global_cluster(host, credentials_provider, rds_client: nil)
        cluster_id = RdsUtils.rds_cluster_id(host)
        client = rds_client || Aws::RDS::Client.new(credentials: credentials_provider)
        arn = client.describe_global_clusters(global_cluster_identifier: cluster_id)
                    .global_clusters
                    .flat_map(&:global_cluster_members)
                    .find(&:is_writer)
                    &.db_cluster_arn
        arn&.match(/\Aarn:aws:rds:(?<region>[^:]+)/)&.[](:region)
      end

      def generate_token(region:, hostname:, port:, user:, credentials_provider:)
        Aws::RDS::AuthTokenGenerator
          .new(credentials: credentials_provider)
          .auth_token(region:, endpoint: "#{hostname}:#{port}", user_name: user)
      end

      def resolve_host(iam_host, host_info)
        return iam_host if iam_host && !iam_host.empty?

        host_info.host
      end

      def resolve_port(iam_default_port, host_info, dialect_default_port)
        iam_port = iam_default_port.to_i
        return iam_port if iam_port.positive?

        return host_info.port.to_i if host_info.port_specified?

        dialect_default_port
      end

      def cache_key(region, host, port, user)
        "#{region}:#{host}:#{port}:#{user}"
      end
    end
  end
end
