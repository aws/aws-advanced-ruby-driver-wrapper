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

module AwsAdvancedRubyDriverWrapper
  module PropertyDefinition
    POSITIVE_INTEGER = lambda do |val, name|
      raise ArgumentError, "#{name} must be a positive integer, got: #{val.inspect}" unless val&.to_i&.positive?
    end

    NON_NEGATIVE_INTEGER = lambda do |val, name|
      raise ArgumentError, "#{name} must be a non-negative integer, got: #{val.inspect}" if val&.to_i&.negative?
    end

    POSITIVE_FLOAT = lambda do |val, name|
      raise ArgumentError, "#{name} must be a positive number, got: #{val.inspect}" unless val&.to_f&.positive?
    end

    NON_NEGATIVE_FLOAT = lambda do |val, name|
      raise ArgumentError, "#{name} must be a non-negative number, got: #{val.inspect}" if val&.to_f&.negative?
    end

    # Upper bound for the IAM token cache TTL. An RDS IAM auth token is only valid for 15 minutes
    # (900s), so the cache must expire strictly before then to guarantee a cached token is never
    # reused past its lifetime.
    IAM_MAX_EXPIRATION_SEC = 870.0

    IAM_EXPIRATION_SEC_BOUND = lambda do |val, name|
      f = val&.to_f
      unless f&.positive? && f <= IAM_MAX_EXPIRATION_SEC
        raise ArgumentError,
              "#{name} must be greater than 0 and at most #{IAM_MAX_EXPIRATION_SEC} seconds " \
              "(the maximum keeps the IAM token cache below its 15-minute validity), got: #{val.inspect}"
      end
    end

    # -- General --
    CLUSTER_ID = WrapperProperty.new(:cluster_id, 'Unique identifier for the database cluster', default_value: '1', type: String)
    PLUGINS = WrapperProperty.new(:wrapper_plugins, 'Comma-separated list of plugin codes', default_value: 'failover,initial_connection',
                                                                                            type: String)
    DIALECT = WrapperProperty.new(:wrapper_dialect, 'The database dialect identifier for the database in use.', type: String)
    AWS_CREDENTIALS_PROVIDER = WrapperProperty.new(:aws_credentials_provider,
                                                   'AWS credentials provider for IAM token generation or Secrets Manager',
                                                   default_value: nil)
    # -- Failover --
    FAILOVER_TIMEOUT_SEC = WrapperProperty.new(
      :failover_timeout_sec,
      'Maximum allowed time in seconds for the failover process.',
      default_value: 300.0,
      type: Float,
      validator: POSITIVE_FLOAT
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

    # -- GDB Failover --
    IN_HOME_FAILOVER_MODE = WrapperProperty.new(
      :in_home_failover_mode,
      'GDB-only: the host role to target during failover while the GDB primary region is the home region. ' \
      'Valid values are strict_writer, strict_home_reader, strict_out_of_home_reader, strict_any_reader, ' \
      'home_reader_or_writer, out_of_home_reader_or_writer, and any_reader_or_writer.',
      default_value: nil,
      type: String
    )
    OUT_OF_HOME_FAILOVER_MODE = WrapperProperty.new(
      :out_of_home_failover_mode,
      'GDB-only: the host role to target during failover while the GDB primary region is not the home region. ' \
      'Accepts the same values as in_home_failover_mode.',
      default_value: nil,
      type: String
    )
    FAILOVER_HOME_REGION = WrapperProperty.new(
      :failover_home_region,
      'GDB-only: the AWS region the application runs in, e.g. us-east-1. Determines which of ' \
      'in_home_failover_mode and out_of_home_failover_mode applies: the in-home mode is used while the GDB ' \
      'primary is in this region, and the out-of-home mode is used while it is not. Defaults to the region ' \
      'parsed from the connection endpoint, and is required when the endpoint carries no region, e.g. a global ' \
      'endpoint, an IP address, or a custom domain.',
      default_value: nil,
      type: String
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
    CLUSTER_TOPOLOGY_REFRESH_RATE_SEC = WrapperProperty.new(
      :cluster_topology_refresh_rate_sec,
      'Cluster topology refresh rate in seconds',
      default_value: 5.0,
      type: Float,
      validator: POSITIVE_FLOAT
    )
    CLUSTER_TOPOLOGY_HIGH_REFRESH_RATE_SEC = WrapperProperty.new(
      :cluster_topology_high_refresh_rate_sec,
      'Cluster topology high refresh rate in seconds (used post-failover)',
      default_value: 0.1,
      type: Float,
      validator: POSITIVE_FLOAT
    )
    CLUSTER_TOPOLOGY_MAX_INSTANCE_MONITORS = WrapperProperty.new(
      :cluster_topology_max_instance_monitors,
      'Maximum number of parallel instance monitors during topology updates',
      default_value: 16,
      type: Integer
    )

    # -- Blue/Green --
    BGD_ID = WrapperProperty.new(:bgd_id, 'Blue/Green Deployment identifier that helps the driver to distinguish different deployments.',
                                 default_value: '1', type: String)
    BG_CONNECT_TIMEOUT_SEC = WrapperProperty.new(:bg_connect_timeout_sec, 'Blue/Green connect timeout in seconds',
                                                 default_value: 30.0, type: Float, validator: POSITIVE_FLOAT)
    BG_INTERVAL_BASELINE_SEC = WrapperProperty.new(:bg_baseline_sec,
                                                   'Baseline Blue/Green Deployment status checking interval (in seconds).',
                                                   default_value: 60.0, type: Float, validator: POSITIVE_FLOAT)
    BG_INTERVAL_INCREASED_SEC = WrapperProperty.new(:bg_increased_sec,
                                                    'Increased Blue/Green Deployment status checking interval (in seconds).',
                                                    default_value: 1.0, type: Float, validator: POSITIVE_FLOAT)
    BG_INTERVAL_HIGH_SEC = WrapperProperty.new(:bg_high_sec, 'High Blue/Green Deployment status checking interval (in seconds).',
                                               default_value: 0.1, type: Float, validator: POSITIVE_FLOAT)
    BG_SWITCHOVER_TIMEOUT_SEC = WrapperProperty.new(:bg_switchover_timeout_sec, 'Blue/Green Deployment switchover timeout (in seconds).',
                                                    default_value: 180.0, type: Float, validator: POSITIVE_FLOAT)

    # -- IAM Authentication --
    IAM_HOST = WrapperProperty.new(:iam_host, 'Overrides the host used to generate the IAM token', default_value: nil, type: String)
    IAM_PORT = WrapperProperty.new(:iam_port, 'Overrides the port used to generate the IAM token', default_value: nil, type: Integer)
    IAM_REGION = WrapperProperty.new(:iam_region, 'Overrides the AWS region used to generate the IAM token', default_value: nil,
                                                                                                             type: String)
    IAM_EXPIRATION_SEC = WrapperProperty.new(:iam_expiration_sec,
                                             'IAM token cache expiration in seconds.',
                                             default_value: IAM_MAX_EXPIRATION_SEC, type: Float, validator: IAM_EXPIRATION_SEC_BOUND)
    IAM_ACCESS_TOKEN_PROPERTY_NAME = WrapperProperty.new(:iam_access_token_property_name, 'Property name used to pass the IAM token',
                                                         default_value: :password, type: Symbol)

    # -- Initial Connection Strategy --
    INITIAL_CONNECTION_SUBSTITUTE_HOST = WrapperProperty.new(
      :initial_connection_substitute_host,
      'Role to substitute the endpoint with: writer, reader, any, or none. Auto-detects from endpoint type when not set.',
      default_value: nil, type: String
    )
    INITIAL_CONNECTION_VERIFY_ROLE = WrapperProperty.new(
      :initial_connection_verify_role,
      'Role to verify after connecting: writer, reader, or none. Auto-detects from endpoint type when not set.',
      default_value: nil, type: String
    )
    INITIAL_CONNECTION_HOST_SELECTOR_STRATEGY = WrapperProperty.new(
      :initial_connection_host_selector_strategy,
      'Strategy name for selecting a host when multiple match the substitution role.',
      default_value: 'random', type: String
    )
    INITIAL_CONNECTION_RETRY_TIMEOUT_SEC = WrapperProperty.new(
      :initial_connection_retry_timeout_sec,
      'Maximum time in seconds to retry opening a connection.',
      default_value: 30.0, type: Float, validator: POSITIVE_FLOAT
    )
    INITIAL_CONNECTION_RETRY_INTERVAL_SEC = WrapperProperty.new(
      :initial_connection_retry_interval_sec,
      'Time in seconds between retries when opening a connection.',
      default_value: 1.0, type: Float, validator: POSITIVE_FLOAT
    )
    INITIAL_CONNECTION_WAIT_FOR_TOPOLOGY_SEC = WrapperProperty.new(
      :initial_connection_wait_for_topology_sec,
      'Maximum allowed time, in seconds, to wait for the cluster topology to be fetched before opening a new ' \
      'connection. When set to a value greater than 0 and the topology is not yet available, the plugin ' \
      'will block until the topology has been discovered (or this timeout is reached) instead of falling ' \
      'back to connecting via the initial endpoint in the connection string.',
      default_value: 0.0, type: Float, validator: NON_NEGATIVE_FLOAT
    )
    INITIAL_CONNECTION_INACTIVE_SUBSTITUTE_HOST = WrapperProperty.new(
      :initial_connection_inactive_substitute_host,
      'GDB-only: substitution role for inactive cluster writer endpoints. Valid values are writer or ' \
      'none. When unset, the endpoint is passed through without substitution.',
      default_value: nil, type: String
    )
    INITIAL_CONNECTION_INACTIVE_VERIFY_ROLE = WrapperProperty.new(
      :initial_connection_inactive_verify_role,
      'GDB-only: verification role for inactive cluster writer endpoints. Valid values are writer or ' \
      'none. When unset, no role verification is performed unless a writer was substituted.',
      default_value: nil, type: String
    )
    ACCESSIBLE_REGIONS = WrapperProperty.new(
      :accessible_regions,
      'Comma-separated list of AWS regions accessible by the application. All regions allowed when not set.',
      default_value: nil, type: String
    )

    # -- Custom Endpoint --
    CUSTOM_ENDPOINT_INFO_REFRESH_RATE_SEC = WrapperProperty.new(
      :custom_endpoint_info_refresh_rate_sec,
      'How frequently custom endpoint monitors fetch custom endpoint info, in seconds.',
      default_value: 30.0,
      type: Float,
      validator: POSITIVE_FLOAT
    )
    CUSTOM_ENDPOINT_INFO_REFRESH_RATE_BACKOFF_FACTOR = WrapperProperty.new(
      :custom_endpoint_info_refresh_rate_backoff_factor,
      'Exponential backoff factor for the custom endpoint monitor on throttling.',
      default_value: 2,
      type: Integer
    )
    CUSTOM_ENDPOINT_INFO_MAX_REFRESH_RATE_SEC = WrapperProperty.new(
      :custom_endpoint_info_max_refresh_rate_sec,
      'Maximum wait between custom endpoint info fetches, in seconds.',
      default_value: 300.0,
      type: Float,
      validator: POSITIVE_FLOAT
    )
    WAIT_FOR_CUSTOM_ENDPOINT_INFO = WrapperProperty.new(
      :wait_for_custom_endpoint_info,
      'Controls whether to wait for custom endpoint info to become available before connecting or executing a ' \
      'method. Waiting is only necessary if a connection to a given custom endpoint has not been opened or used ' \
      'recently. Note that disabling this may result in occasional connections to instances outside of the ' \
      'custom endpoint.',
      default_value: true,
      type: :boolean
    )
    WAIT_FOR_CUSTOM_ENDPOINT_INFO_TIMEOUT_SEC = WrapperProperty.new(
      :wait_for_custom_endpoint_info_timeout_sec,
      'Maximum time to wait for custom endpoint info, in seconds.',
      default_value: 5.0,
      type: Float,
      validator: POSITIVE_FLOAT
    )
    CUSTOM_ENDPOINT_MONITOR_EXPIRATION_SEC = WrapperProperty.new(
      :custom_endpoint_monitor_expiration_sec,
      'How long a monitor runs without use before expiring, in seconds.',
      default_value: 900.0,
      type: Float,
      validator: POSITIVE_FLOAT
    )
    CUSTOM_ENDPOINT_REGION = WrapperProperty.new(
      :custom_endpoint_region,
      'Region of the custom endpoint. Parsed from the URL when not specified.',
      default_value: nil,
      type: String
    )

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
      default_value: 870.0, type: Float, validator: POSITIVE_FLOAT
    )
    SECRET_ROTATION_RETRY_TIMEOUT_SEC = WrapperProperty.new(
      :secret_rotation_retry_timeout_sec,
      'Max time in seconds to retry connecting during a secret rotation window (0 = disabled)',
      default_value: 0.0, type: Float, validator: NON_NEGATIVE_FLOAT
    )
    SECRET_ROTATION_RETRY_BASE_DELAY_SEC = WrapperProperty.new(
      :secret_rotation_retry_base_delay_sec,
      'Base delay in seconds for exponential backoff during rotation retry',
      default_value: 0.5, type: Float, validator: POSITIVE_FLOAT
    )

    # -- KMS Encryption --
    ENCRYPTION_KMS_REGION = WrapperProperty.new(
      :encryption_kms_region,
      'AWS region for KMS calls made by the kms_encryption plugin. Required: falls back to the ' \
      'AWS_REGION or AWS_DEFAULT_REGION environment variable, and is rejected if none is set.',
      default_value: nil, type: String
    )
    ENCRYPTION_KMS_ENDPOINT = WrapperProperty.new(
      :encryption_kms_endpoint, 'Custom endpoint URL for KMS', default_value: nil, type: String
    )
    ENCRYPTION_METADATA_SCHEMA = WrapperProperty.new(
      :encryption_metadata_schema,
      'Schema holding the encryption_metadata and key_storage tables',
      default_value: 'encrypt', type: String
    )
    ENCRYPTION_METADATA_CACHE_ENABLED = WrapperProperty.new(
      :encryption_metadata_cache_enabled,
      'Cache the kms_encryption metadata in memory instead of querying it per statement',
      default_value: true, type: :boolean
    )
    ENCRYPTION_METADATA_CACHE_EXPIRATION_SEC = WrapperProperty.new(
      :encryption_metadata_cache_expiration_sec,
      'How long cached kms_encryption metadata stays valid, in seconds',
      default_value: 3600.0, type: Float, validator: POSITIVE_FLOAT
    )
    ENCRYPTION_METADATA_CACHE_REFRESH_INTERVAL_SEC = WrapperProperty.new(
      :encryption_metadata_cache_refresh_interval_sec,
      'How often the kms_encryption metadata is refreshed in the background, in seconds (0 disables background refresh)',
      default_value: 300.0, type: Float, validator: NON_NEGATIVE_FLOAT
    )
    ENCRYPTION_KEY_MANAGEMENT_MAX_RETRIES = WrapperProperty.new(
      :encryption_key_management_max_retries,
      'Maximum number of retries for throttled or failed KMS calls',
      default_value: 3, type: Integer, validator: NON_NEGATIVE_INTEGER
    )
    ENCRYPTION_KEY_MANAGEMENT_RETRY_BACKOFF_BASE_SEC = WrapperProperty.new(
      :encryption_key_management_retry_backoff_base_sec,
      'Base delay in seconds for the exponential backoff between KMS retries',
      default_value: 0.1, type: Float, validator: POSITIVE_FLOAT
    )
    ENCRYPTION_AUDIT_LOGGING_ENABLED = WrapperProperty.new(
      :encryption_audit_logging_enabled,
      'Log an audit record for every key management, kms_encryption, and decryption operation',
      default_value: false, type: :boolean
    )
    ENCRYPTION_RETURN_UNVERIFIED_DATA = WrapperProperty.new(
      :encryption_return_unverified_data,
      'On read, return a value as it is stored when it cannot be confirmed to be valid encrypted data ' \
      '(too short to be a payload, or a failed HMAC) instead of raising. Intended only for reading data ' \
      'written before kms_encryption was enabled. MUST NOT be enabled in production: it lets unverified ' \
      'data reach the application. A value that verifies but cannot be decrypted still raises.',
      default_value: false, type: :boolean
    )
    ENCRYPTION_DATA_KEY_CACHE_ENABLED = WrapperProperty.new(
      :encryption_data_key_cache_enabled,
      'Cache decrypted data keys in memory to avoid a KMS Decrypt call per statement',
      default_value: true, type: :boolean
    )
    ENCRYPTION_DATA_KEY_CACHE_MAX_SIZE = WrapperProperty.new(
      :encryption_data_key_cache_max_size,
      'Maximum number of decrypted data keys held in memory',
      default_value: 1000, type: Integer, validator: POSITIVE_INTEGER
    )
    ENCRYPTION_DATA_KEY_CACHE_EXPIRATION_SEC = WrapperProperty.new(
      :encryption_data_key_cache_expiration_sec,
      'How long a decrypted data key stays cached, in seconds',
      default_value: 300.0, type: Float, validator: POSITIVE_FLOAT
    )

    # Built once at load time from constants — used by parser to split props
    KNOWN_PROPERTIES = constants
                       .filter_map { |c| const_get(c) if const_get(c).is_a?(WrapperProperty) }
                       .to_h { |prop| [prop.name, prop] }
                       .freeze

    # Known prefixes for internal connection overrides. Each prefix maps to a key
    # used in ConnectionConfig#prefixed_wrapper_config and ConnectionConfig#prefixed_driver_config.
    # Plugins define their own prefix here.
    TOPOLOGY_MONITORING_PREFIX = 'topology_monitoring_'
    BG_MONITORING_PROPERTY_PREFIX = 'bg_monitoring_'

    KNOWN_PREFIXES = [
      TOPOLOGY_MONITORING_PREFIX,
      BG_MONITORING_PROPERTY_PREFIX
    ].freeze

    BG_STORAGE_NAMESPACE = '941d00a8-8238-4f7d-bf59-771bff783a8e'

    def self.wrapper_property?(key)
      KNOWN_PROPERTIES.key?(key.to_sym)
    end
  end
end
