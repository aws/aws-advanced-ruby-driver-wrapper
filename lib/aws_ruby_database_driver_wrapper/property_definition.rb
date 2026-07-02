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

require_relative 'wrapper_property'

module AwsRubyDatabaseDriverWrapper
  module PropertyDefinition
    # -- General --
    CLUSTER_ID = WrapperProperty.new(:cluster_id, 'Unique identifier for the database cluster', default_value: '1', type: String)
    PLUGINS = WrapperProperty.new(:wrapper_plugins, 'Comma-separated list of plugin codes', default_value: 'failover', type: String)
    DIALECT = WrapperProperty.new(:wrapper_dialect, 'The database dialect identifier for the database in use.', type: String)

    # -- Failover --
    FAILOVER_TIMEOUT_SEC = WrapperProperty.new(
      :failover_timeout_sec,
      'Maximum allowed time in seconds for the failover process.',
      default_value: 300,
      type: Integer
    )
    FAILOVER_MODE = WrapperProperty.new(
      :failover_mode,
      'Set the desired instance role to target during failover.',
      default_value: nil,
      type: String
    )
    FAILOVER_READER_HOST_SELECTOR_STRATEGY = WrapperProperty.new(
      :failover_reader_host_selector_strategy,
      'The strategy that should be used to select a new reader host while opening a new connection.',
      default_value: 'random',
      type: String
    )
    ENABLE_CONNECT_FAILOVER = WrapperProperty.new(
      :enable_connect_failover,
      'Enable/disable cluster-aware failover if the initial connection fails due to a network exception.',
      default_value: false,
      type: :boolean
    )

    # -- Topology Monitoring --
    CLUSTER_INSTANCE_HOST_PATTERN = WrapperProperty.new(
      :cluster_instance_host_pattern,
      'Instance endpoint pattern with ? placeholder. Required for IP/custom domain connections.',
      default_value: nil,
      type: String
    )
    GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS = WrapperProperty.new(
      :global_cluster_instance_host_patterns,
      'Comma-separated list of region-prefixed instance patterns for Global Aurora Databases.',
      default_value: nil,
      type: String
    )
    CLUSTER_TOPOLOGY_REFRESH_RATE_MS = WrapperProperty.new(
      :cluster_topology_refresh_rate_ms,
      'Cluster topology refresh rate in milliseconds',
      default_value: 5000,
      type: Integer
    )
    CLUSTER_TOPOLOGY_HIGH_REFRESH_RATE_MS = WrapperProperty.new(
      :cluster_topology_high_refresh_rate_ms,
      'Cluster topology high refresh rate in milliseconds (used post-failover)',
      default_value: 100,
      type: Integer
    )
    CLUSTER_TOPOLOGY_MAX_INSTANCE_MONITORS = WrapperProperty.new(
      :cluster_topology_max_instance_monitors,
      'Maximum number of parallel instance monitors during topology updates',
      default_value: 16,
      type: Integer
    )

    # -- IAM Authentication --
    IAM_HOST = WrapperProperty.new(:iam_host, 'Overrides the host used to generate the IAM token', default_value: nil, type: String)
    IAM_PORT = WrapperProperty.new(:iam_port, 'Overrides the port used to generate the IAM token', default_value: nil, type: Integer)
    IAM_REGION = WrapperProperty.new(:iam_region, 'Overrides the AWS region used to generate the IAM token', default_value: nil,
                                                                                                             type: String)
    IAM_EXPIRATION = WrapperProperty.new(:iam_expiration, 'IAM token cache expiration in seconds', default_value: 870, type: Integer)
    IAM_ACCESS_TOKEN_PROPERTY_NAME = WrapperProperty.new(:iam_access_token_property_name, 'Property name used to pass the IAM token',
                                                         default_value: :password, type: Symbol)
    IAM_CREDENTIALS_PROVIDER = WrapperProperty.new(:iam_credentials_provider,
                                                   'AWS credentials provider for IAM token generation',
                                                   default_value: nil)

    # -- Secrets Manager --
    SECRET_ID = WrapperProperty.new(
      :secret_id, 'The name or ARN of the secret to retrieve', default_value: nil, type: String
    )
    SECRET_REGION = WrapperProperty.new(
      :secret_region, 'AWS region for Secrets Manager API calls', default_value: nil, type: String
    )
    SECRET_ENDPOINT = WrapperProperty.new(
      :secret_endpoint, 'Custom endpoint URL for Secrets Manager', default_value: nil, type: String
    )
    SECRET_USERNAME_KEY = WrapperProperty.new(
      :secret_username_key, 'JSON key containing the username in the secret',
      default_value: 'username', type: String
    )
    SECRET_PASSWORD_KEY = WrapperProperty.new(
      :secret_password_key, 'JSON key containing the password in the secret',
      default_value: 'password', type: String
    )
    SECRET_EXPIRATION_SEC = WrapperProperty.new(
      :secret_expiration_sec, 'Cached secret expiration in seconds (minimum: 300)',
      default_value: 870, type: Integer
    )
    SECRET_CREDENTIALS_PROVIDER = WrapperProperty.new(
      :secret_credentials_provider, 'Custom AWS credentials provider for Secrets Manager',
      default_value: nil
    )
    SECRET_ROTATION_RETRY_TIMEOUT_MS = WrapperProperty.new(
      :secret_rotation_retry_timeout_ms,
      'Max time in milliseconds to retry connecting during a secret rotation window (0 = disabled)',
      default_value: 0, type: Integer
    )
    SECRET_ROTATION_RETRY_BASE_DELAY_MS = WrapperProperty.new(
      :secret_rotation_retry_base_delay_ms,
      'Base delay in milliseconds for exponential backoff during rotation retry',
      default_value: 500, type: Integer
    )

    # Built once at load time from constants — used by parser to split props
    KNOWN_PROPERTIES = constants
                       .filter_map { |c| const_get(c) if const_get(c).is_a?(WrapperProperty) }
                       .to_h { |prop| [prop.name, prop] }
                       .freeze

    # Known prefixes for internal connection overrides. Each prefix maps to a key
    # used in ConnectionConfig#prefixed_props. Plugins define their own prefix here.
    TOPOLOGY_MONITORING_PREFIX = 'topology_monitoring_'

    KNOWN_PREFIXES = [
      TOPOLOGY_MONITORING_PREFIX
    ].freeze

    def self.wrapper_property?(key)
      KNOWN_PROPERTIES.key?(key.to_sym)
    end
  end
end
