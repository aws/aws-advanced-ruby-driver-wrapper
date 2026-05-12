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

    # -- Blue Green --
    ENABLE_GREEN_NODE_REPLACEMENT = WrapperProperty.new(
      :enable_green_node_replacement,
      'Enable green node DNS correction on connect failure for blue/green deployments',
      default_value: false
    )

    # -- Failover --
    FAILOVER_TIMEOUT_SEC = WrapperProperty.new(:failover_timeout_sec, 'Failover timeout in seconds', default_value: 300)
    FAILOVER_CLUSTER_TOPOLOGY_REFRESH_RATE_SEC = WrapperProperty.new(
      :failover_cluster_topology_refresh_rate_sec,
      'Topology refresh rate during failover in seconds',
      default_value: 2
    )

    # Built once at load time from constants — used by parser to split props
    KNOWN_PROPERTIES = constants
                       .filter_map { |c| const_get(c) if const_get(c).is_a?(WrapperProperty) }
                       .to_h { |prop| [prop.name, prop] }
                       .freeze

    def self.wrapper_property?(key)
      KNOWN_PROPERTIES.key?(key.to_sym)
    end
  end
end
