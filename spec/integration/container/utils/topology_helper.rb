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

require_relative 'driver_helper'
require_relative 'retry_helper'
require 'aws_advanced_ruby_driver_wrapper'

module Integration
  # Shared helpers for reading and warming the wrapper's cluster topology cache.
  #
  # Substitution by the initial_connection plugin, and topology-driven failover, both depend on the
  # topology monitor having discovered the cluster's instance hosts. On a cold cache the plugins have
  # only the cluster endpoint to work with. These helpers let a spec warm the cache with a throwaway
  # connection and block until the instance hosts have actually landed, so an assertion that follows is
  # not racing the background monitor. Used by failover_spec, iam_auth_spec, secrets_manager_spec, and
  # the initial_connection strategy spec so the behavior is defined in exactly one place.
  module TopologyHelper
    module_function

    # Reads the cached topology host list for a cluster id, or nil if nothing is cached yet.
    def cached_hosts(cluster_id)
      AwsAdvancedRubyDriverWrapper::Services::CoreServices.storage_service.get(
        :topology, cluster_id, register_access: false
      )
    end

    # Resolves the cluster id a connection with these props will cache its topology under. The RDS host
    # list provider keys the topology cache on the CLUSTER_ID property, so watchers must use the same value
    # or they gate on a different - possibly stale, cross-test - cache entry.
    #
    # @param props [Hash] wrapper properties
    # @return [String] the CLUSTER_ID property value, or its default when unset
    def cluster_id_from(props)
      AwsAdvancedRubyDriverWrapper::PropertyDefinition::CLUSTER_ID.get(props)
    end

    # Blocks until the topology cache for cluster_id satisfies the discovery criteria.
    #
    # @param cluster_id [String] the cluster id the topology is cached under. This MUST match the CLUSTER_ID
    #   property of the connection whose topology is being awaited (see #cluster_id_from); a mismatch silently
    #   watches the wrong cache entry.
    # @param min_instances [Integer] minimum number of hosts that must be present (default: 1)
    # @param require_instance_hosts [Boolean] when true, at least one cached host must be an RDS
    #   instance endpoint (proves the monitor moved past the initial cluster endpoint)
    # @param instance_suffix [String, nil] when set, every cached host must end with this suffix
    #   (used to assert proxied instance hosts rather than real ones)
    # @return [Boolean] true if the criteria were met within the timeout, false otherwise
    def wait_for_topology(cluster_id: AwsAdvancedRubyDriverWrapper::PropertyDefinition::CLUSTER_ID.default_value,
                          min_instances: 1, require_instance_hosts: true, instance_suffix: nil,
                          timeout_secs: 30, delay_secs: 0.5)
      Integration::RetryHelper.retry_until(timeout_secs: timeout_secs, delay_secs: delay_secs) do
        hosts = cached_hosts(cluster_id)
        next false if hosts.nil? || hosts.size < min_instances

        next false if require_instance_hosts && hosts.none? { |h| AwsAdvancedRubyDriverWrapper::Utils::RdsUtils.rds_instance?(h.host) }
        next false if instance_suffix && !hosts.all? { |h| h.host.end_with?(instance_suffix) }

        true
      end
    end

    # Opens a throwaway connection to warm the topology cache and dialect, closes it, then blocks until
    # the instance hosts have landed in the cache. Returns true once the topology is discovered.
    #
    # @param drv the test driver (Integration::TestDriver::PG / MYSQL)
    # @param config [Hash] native driver connection config
    # @param props [Hash] wrapper properties (must enable whatever populates topology)
    # @param cluster_id [String, nil] the cluster id the topology is cached under. Defaults to the value
    #   derived from props (see #cluster_id_from) so the watcher always matches the connection being warmed;
    #   only override when intentionally awaiting a different cluster id.
    # @param (see #wait_for_topology) for the remaining discovery criteria
    # @return [Boolean] true if the topology was discovered within the timeout, false otherwise
    def warm_topology_cache(drv:, config:, props:, cluster_id: nil, min_instances: 1,
                            require_instance_hosts: true, instance_suffix: nil, timeout_secs: 30, delay_secs: 0.5)
      cluster_id ||= cluster_id_from(props)

      warmup = Integration::DriverHelper.wrapper_connect(drv, **config, **props)
      Integration::DriverHelper.close(drv, warmup)

      wait_for_topology(
        cluster_id: cluster_id,
        min_instances: min_instances,
        require_instance_hosts: require_instance_hosts,
        instance_suffix: instance_suffix,
        timeout_secs: timeout_secs,
        delay_secs: delay_secs
      )
    end
  end
end
