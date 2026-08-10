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

require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/database_engine'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/proxy_helper'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require_relative 'utils/test_round_robin_host_selector'
require_relative 'utils/test_utils'
require 'aws_ruby_database_driver_wrapper'
require 'aws_ruby_database_driver_wrapper/db_dialects/dialect_codes'

# Integration tests for the InitialConnectionStrategyPlugin.
#
# The plugin's behavior is largely internal: it can substitute the initial connection URL with an
# instance URL from the topology, and it can verify the role of the host it connected to. Neither
# is visible from the resulting connection object on its own. Both are observable through
# ConnectionService#current_host_info.
RSpec.describe 'InitialConnectionStrategy', :integration,
               deployments: [Integration::DatabaseEngineDeployment::AURORA],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_utils) { AwsRubyDatabaseDriverWrapper::Utils::RdsUtils }
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:props) { AwsRubyDatabaseDriverWrapper::PropertyDefinition }

  let(:initial_connection_props) do
    base_wrapper_props.merge(
      props::PLUGINS.name => 'initialConnection'
    )
  end

  let(:explicit_dialect) do
    case env.engine
    when Integration::DatabaseEngine::PG then AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG
    when Integration::DatabaseEngine::MYSQL then AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL
    else raise "Unsupported engine: #{env.engine}"
    end
  end

  let(:reader_cluster_config) do
    Integration::DriverHelper.native_config(
      drv,
      host: info.cluster_read_only_endpoint,
      port: info.cluster_read_only_endpoint_port,
      user: info.username,
      password: info.password,
      dbname: info.default_dbname
    )
  end

  let(:writer_cluster_config) do
    Integration::DriverHelper.native_config(
      drv,
      host: info.cluster_endpoint,
      port: info.cluster_endpoint_port,
      user: info.username,
      password: info.password,
      dbname: info.default_dbname
    )
  end

  # The host the connection was actually established against, after any substitution the plugin performed.
  def connected_host(conn)
    conn.instance_variable_get(:@service_container).connection_service.current_host_info.host
  end

  # Populates the shared topology cache with a throwaway connection. Substitution requires a known
  # topology, and on a cold cache the plugin declines to substitute because the topology monitor will
  # not start until the dialect is final, which only happens once DefaultPlugin#connect has confirmed
  # it against a live connection. Connecting once first both finalizes the dialect for the endpoint
  # and leaves the topology cached for the connection under test.
  def warm_topology_cache(config)
    conn = Integration::DriverHelper.wrapper_connect(drv, **config, **initial_connection_props)
    Integration::DriverHelper.close(drv, conn)
  end

  before do
    skip 'No allowed drivers for this environment' if drv.nil?
  end

  describe 'endpoint substitution' do
    # Substitution requires at least one reader to select from the topology.
    before { enable_on_num_instances(min_instances: 2) }

    it 'substitutes a reader instance endpoint after waiting for topology on a cold cache' do
      # Start from a cold topology cache so the plugin has nothing but the cluster endpoint to work
      # with and must wait for the topology monitor, as during a real application startup.
      AwsRubyDatabaseDriverWrapper.clear_caches

      # The topology monitor will not start until the dialect is final, and on a cold cache the
      # dialect is only guessed from the URL until DefaultPlugin#connect confirms it, which happens
      # after the plugin has already decided. Setting the dialect explicitly makes it final up front
      # so the plugin genuinely waits for topology rather than falling back to the cluster endpoint.
      cold_props = initial_connection_props.merge(
        props::DIALECT.name => explicit_dialect,
        props::INITIAL_CONNECTION_WAIT_FOR_TOPOLOGY_MS.name => 30_000
      )

      conn = Integration::DriverHelper.wrapper_connect(drv, **reader_cluster_config, **cold_props)

      host = connected_host(conn)
      expect(host).not_to eq(info.cluster_read_only_endpoint)
      expect(rds_utils.rds_instance?(host)).to be true

      # The substituted instance must actually be a reader, verified independently of the plugin.
      expect(Integration::RdsTestUtility.query_host_role(conn, env.engine)).to eq(:reader)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'substitutes a reader instance endpoint from a warm topology cache' do
      # Assert that a connection substitutes immediately using the cached topology, without being
      # configured to wait for it.
      warm_topology_cache(reader_cluster_config)

      conn = Integration::DriverHelper.wrapper_connect(drv, **reader_cluster_config, **initial_connection_props)

      host = connected_host(conn)
      expect(host).not_to eq(info.cluster_read_only_endpoint)
      expect(rds_utils.rds_instance?(host)).to be true
      expect(Integration::RdsTestUtility.query_host_role(conn, env.engine)).to eq(:reader)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'substitutes a writer instance endpoint for a writer cluster endpoint' do
      warm_topology_cache(writer_cluster_config)

      conn = Integration::DriverHelper.wrapper_connect(drv, **writer_cluster_config, **initial_connection_props)

      host = connected_host(conn)
      expect(host).not_to eq(info.cluster_endpoint)
      expect(rds_utils.rds_instance?(host)).to be true
      expect(Integration::RdsTestUtility.query_host_role(conn, env.engine)).to eq(:writer)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'leaves the reader cluster endpoint untouched when substitution is disabled' do
      disabled_props = initial_connection_props.merge(
        props::INITIAL_CONNECTION_SUBSTITUTE_HOST.name => 'none'
      )

      conn = Integration::DriverHelper.wrapper_connect(drv, **reader_cluster_config, **disabled_props)

      # With substitution explicitly disabled the plugin must connect via the endpoint as provided.
      expect(connected_host(conn)).to eq(info.cluster_read_only_endpoint)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  describe 'endpoint passthrough' do
    it 'leaves an instance endpoint untouched' do
      # Only cluster-type endpoints are eligible for substitution or role verification. The plugin
      # returns early for everything else, so an instance endpoint must be connected to as given even
      # though a full topology is available to substitute from.
      instance_config = Integration::DriverHelper.native_config(
        drv,
        host: writer.host,
        port: writer.port,
        user: info.username,
        password: info.password,
        dbname: info.default_dbname
      )
      warm_topology_cache(reader_cluster_config)

      conn = Integration::DriverHelper.wrapper_connect(drv, **instance_config, **initial_connection_props)

      expect(connected_host(conn)).to eq(writer.host)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  # The reader cluster endpoint is substituted with a reader chosen by the strategy named in
  # INITIAL_CONNECTION_HOST_SELECTOR_STRATEGY. This test uses a test utility round robin
  # selector to ensure spread across instances is assertable rather than probabilistic.
  describe 'reader load balancing' do
    # Two readers are the minimum needed for 'connected to a different instance each time' to mean anything,
    # so the cluster needs a writer plus two readers.
    before { enable_on_num_instances(min_instances: 3) }

    let(:round_robin_props) do
      initial_connection_props.merge(
        props::INITIAL_CONNECTION_HOST_SELECTOR_STRATEGY.name => Integration::TestRoundRobinHostSelector::STRATEGY_NAME
      )
    end

    # The registry is per process, so registering once here covers every connection the example opens, and
    # the one selector's rotation advances from one connection to the next.
    before do
      AwsRubyDatabaseDriverWrapper::Services::HostService.register_host_selector(
        Integration::TestRoundRobinHostSelector::STRATEGY_NAME,
        Integration::TestRoundRobinHostSelector.new
      )
    end

    after { AwsRubyDatabaseDriverWrapper::Services::HostService.reset_host_selectors }

    it 'spreads consecutive connections over every reader instance' do
      # Assigned before anything that can raise so that the ensure block always has a list to close.
      connections = []

      warm_topology_cache(reader_cluster_config)

      # Every instance other than the writer is a reader, so one connection per reader should visit each of
      # them exactly once. Which reader the rotation starts on depends on how the topology sorts, so only the
      # spread over a full cycle is asserted.
      reader_count = env.instances.size - 1
      reader_count.times do
        connections << Integration::DriverHelper.wrapper_connect(drv, **reader_cluster_config, **round_robin_props)
      end

      hosts = connections.map { |conn| connected_host(conn) }
      expect(hosts.uniq.size).to eq(reader_count), "Expected #{reader_count} distinct reader hosts, got #{hosts}"
      expect(hosts).to all(satisfy { |host| rds_utils.rds_instance?(host) })
      connections.each do |conn|
        expect(Integration::RdsTestUtility.query_host_role(conn, env.engine)).to eq(:reader)
      end
    ensure
      connections.each { |conn| Integration::DriverHelper.close(drv, conn) if conn }
    end
  end

  describe 'role verification' do
    it 'accepts a writer connection for a reader cluster endpoint when the cluster has no readers' do
      # A single-instance cluster has no reader to substitute or verify against. Rather than
      # exhausting the retry timeout, the plugin is expected to notice that no readers exist in the
      # topology and accept the writer connection.
      enable_on_num_instances(max_instances: 1)
      warm_topology_cache(reader_cluster_config)

      conn = Integration::DriverHelper.wrapper_connect(drv, **reader_cluster_config, **initial_connection_props)

      expect(Integration::RdsTestUtility.query_host_role(conn, env.engine)).to eq(:writer)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  describe 'connection retry',
           features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
    let(:proxy_info) { env.proxy_database_info }

    # Points the plugin at the proxied instance endpoints so that substituted hosts are reachable only
    # through Toxiproxy, and keeps the retry window short enough to time out within the test.
    let(:retry_props) do
      initial_connection_props.merge(
        props::CLUSTER_INSTANCE_HOST_PATTERN.name =>
          "?.#{proxy_info.instance_endpoint_suffix}:#{proxy_info.instance_endpoint_port}",
        props::INITIAL_CONNECTION_RETRY_TIMEOUT_MS.name => 10_000,
        props::INITIAL_CONNECTION_RETRY_INTERVAL_MS.name => 1000
      )
    end

    let(:proxied_reader_cluster_config) do
      Integration::DriverHelper.native_config(
        drv,
        host: proxy_info.cluster_read_only_endpoint,
        port: proxy_info.cluster_read_only_endpoint_port,
        user: proxy_info.username,
        password: proxy_info.password,
        dbname: proxy_info.default_dbname
      )
    end

    it 'times out when every substitution candidate is unreachable' do
      enable_on_num_instances(min_instances: 2)

      # Warm the topology through the proxies while they are still up, so that the plugin has instance
      # hosts to substitute once connectivity is cut.
      warmup = Integration::DriverHelper.wrapper_connect(drv, **proxied_reader_cluster_config, **retry_props)
      Integration::DriverHelper.close(drv, warmup)

      Integration::ProxyHelper.disable_all_connectivity

      expect do
        conn = Integration::DriverHelper.wrapper_connect(drv, **proxied_reader_cluster_config, **retry_props)
        Integration::DriverHelper.close(drv, conn) if conn
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Initial connection strategy timed out/)
    end
  end

  describe 'after failover',
           features: [Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED] do
    it 'substitutes the new writer instance for a writer cluster endpoint' do
      enable_on_num_instances(min_instances: 2)

      original_writer_id = rds_util.cluster_writer_instance_id
      rds_util.failover_cluster_and_wait_until_writer_changed
      new_writer_id = rds_util.cluster_writer_instance_id

      conn = Integration::DriverHelper.wrapper_connect(drv, **writer_cluster_config, **initial_connection_props)
      host = connected_host(conn)
      expect(host).not_to eq(info.cluster_endpoint)
      expect(rds_utils.rds_instance?(host)).to be true
      # Instance endpoints are '<instance id>.<instance endpoint suffix>'.
      connected_instance_id = host.split('.').first.downcase
      expect(connected_instance_id).to eq(new_writer_id.downcase)
      expect(connected_instance_id).not_to eq(original_writer_id.downcase)
      expect(Integration::RdsTestUtility.query_host_role(conn, env.engine)).to eq(:writer)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end
end
