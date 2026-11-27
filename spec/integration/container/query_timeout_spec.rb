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
require_relative 'utils/test_utils'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/driver_helper'
require_relative 'utils/proxy_helper'
require_relative 'utils/database_engine'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require_relative 'utils/topology_helper'
require 'aws_advanced_ruby_driver_wrapper'

# pg_query_timeout_sec bounds the wrapper's own queries (topology monitor, role checks, dialect detection).
# The scenario is a server that stops answering while its connections stay open, which the proxy simulates by
# silencing the writer's instance proxy after the wrapper has connected (ProxyHelper.silence_connectivity),
# as opposed to dropping the connection, which the driver reports on its own. Without a timeout, the wrapper's
# queries on such a connection block forever (#246).
#
# Dialect detection raising on a timeout (instead of caching the wrong dialect) is covered by
# spec/unit/services/dialect_service_spec.rb. It cannot be driven from here: silence applied before connecting
# stalls the PG startup handshake (connect_timeout), and the first dialect query only runs after it.
RSpec.describe 'Query timeout', :integration,
               features: [Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED,
                          Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA,
                             Integration::DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER],
               enable_on_engines: [Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:query_timeout_sec) { 5 }
  let(:failover_timeout_sec) { 60 }
  # Headroom over failover_timeout_sec for connect, reader/writer verification and cluster jitter.
  let(:failover_slack_sec) { 15 }

  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:proxy_info) { env.proxy_database_info }
  let(:current_writer) { proxy_info.instances.first.instance_id }

  let(:timeout_props) do
    {
      AwsAdvancedRubyDriverWrapper::PropertyDefinition::PLUGINS.name => 'failover',
      AwsAdvancedRubyDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => failover_timeout_sec,
      AwsAdvancedRubyDriverWrapper::PropertyDefinition::PG_QUERY_TIMEOUT_SEC.name => query_timeout_sec,
      AwsAdvancedRubyDriverWrapper::PropertyDefinition::CLUSTER_INSTANCE_HOST_PATTERN.name =>
        "?.#{proxy_info.instance_endpoint_suffix}:#{proxy_info.instance_endpoint_port}",
      connect_timeout: 10,
      **Integration::TelemetryHelper.wrapper_props
    }
  end

  def timeout_connect
    config = Integration::DriverHelper.native_config(
      drv,
      host: proxy_info.cluster_endpoint,
      port: proxy_info.cluster_endpoint_port,
      user: proxy_info.username,
      password: proxy_info.password,
      dbname: proxy_info.default_dbname
    )
    conn = Integration::DriverHelper.wrapper_connect(drv, **config, **timeout_props)
    expect(wait_for_full_topology).to be(true), 'Topology was not fully discovered after establishing a connection'
    conn
  end

  def wait_for_full_topology(timeout_secs: 30)
    Integration::TopologyHelper.wait_for_topology(
      min_instances: proxy_info.instances.size,
      require_instance_hosts: false,
      timeout_secs: timeout_secs,
      delay_secs: 0.5
    )
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  it 'refreshes the topology after the writer stops answering and comes back' do
    enable_on_num_instances(min_instances: 2)
    conn = timeout_connect

    Integration::ProxyHelper.silence_connectivity(current_writer)
    # Long enough for a monitor query in flight on the silent connection to hit the timeout.
    sleep(query_timeout_sec * 2)
    Integration::ProxyHelper.restore_connectivity(current_writer)

    # A monitor still blocked on the silent connection would never refresh again.
    expect(wait_for_full_topology(timeout_secs: failover_timeout_sec)).to be(true),
                                                                          'Topology monitor did not recover after the writer came back'
    expect(Integration::RetryHelper.verify_writer(rds_util, rds_util.query_instance_id(conn))).to be true
  ensure
    Integration::ProxyHelper.restore_connectivity(current_writer)
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'completes writer failover within failover_timeout_sec when the old writer stops answering' do
    enable_on_num_instances(min_instances: 2)
    conn = timeout_connect

    # The application connection goes through the cluster endpoint proxy, which is independent of the writer's
    # instance proxy, so drop it to make the application see the failure. The instance proxy is silenced rather
    # than dropped, so the monitor's connection to the old writer hangs instead of failing.
    Integration::ProxyHelper.disable_proxy(proxy_info.cluster_endpoint)
    Integration::ProxyHelper.silence_connectivity(current_writer)
    rds_util.crash_instance(current_writer)

    started = monotonic_now
    expect { rds_util.query_instance_id(conn) }.to raise_error(
      AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
    )
    elapsed = monotonic_now - started
    expect(elapsed).to be <= failover_timeout_sec + failover_slack_sec

    expect(Integration::RetryHelper.verify_writer(rds_util, rds_util.query_instance_id(conn))).to be true
  ensure
    Integration::ProxyHelper.restore_connectivity(current_writer)
    Integration::DriverHelper.close(drv, conn) if conn
  end
end
