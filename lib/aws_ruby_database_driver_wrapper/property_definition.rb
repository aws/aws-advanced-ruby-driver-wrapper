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
    CLUSTER_ID = WrapperProperty.new(:cluster_id, 'Unique identifier for the database cluster', default_value: '1')
    PLUGINS = WrapperProperty.new(:wrapper_plugins, 'Comma-separated list of plugin codes', default_value: 'failover')
    AUTO_SORT_PLUGIN_ORDER = WrapperProperty.new(:auto_sort_plugin_order, 'Auto-sort plugin execution order', default_value: true)
    DIALECT = WrapperProperty.new(:wrapper_dialect, 'The database dialect identifier for the database in use.')

    # -- Failover --
    FAILOVER_TIMEOUT_SEC = WrapperProperty.new(:failover_timeout_sec, 'Failover timeout in seconds', default_value: 300)

    # -- Topology Monitoring --
    CLUSTER_TOPOLOGY_REFRESH_RATE_MS = WrapperProperty.new(
      :cluster_topology_refresh_rate_ms,
      'Cluster topology refresh rate in milliseconds',
      default_value: 5000
    )
    CLUSTER_TOPOLOGY_HIGH_REFRESH_RATE_MS = WrapperProperty.new(
      :cluster_topology_high_refresh_rate_ms,
      'Cluster topology high refresh rate in milliseconds (used post-failover)',
      default_value: 100
    )
    CLUSTER_TOPOLOGY_MAX_NODE_THREADS = WrapperProperty.new(
      :cluster_topology_max_node_threads,
      'Maximum number of parallel node monitoring threads during failover',
      default_value: 16
    )

    # Built once at load time from constants — used by parser to split props
    KNOWN_PROPERTIES = constants
                       .filter_map { |c| const_get(c) if const_get(c).is_a?(WrapperProperty) }
                       .to_h { |prop| [prop.name, prop] }
                       .freeze

    # Known prefixes for internal connection overrides. Each prefix maps to a key
    # used in ConnectionConfig#prefixed_props. Plugins define their own prefix here.
    TOPOLOGY_MONITORING_PREFIX = 'topology-monitoring-'

    KNOWN_PREFIXES = [
      TOPOLOGY_MONITORING_PREFIX
    ].freeze

    def self.wrapper_property?(key)
      KNOWN_PROPERTIES.key?(key.to_sym)
    end
  end
end
