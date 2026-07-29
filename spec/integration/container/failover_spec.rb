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
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/proxy_helper'
require_relative 'utils/connection_utils'
require_relative 'utils/database_engine'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require 'aws_ruby_database_driver_wrapper'

RSpec.describe 'Failover', :integration,
               features: [Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA, Integration::DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:proxy_info) { env.proxy_database_info }
  let(:current_writer) { proxy_info.instances.first.instance_id }

  let(:failover_props) do
    {
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::PLUGINS.name => 'failover',
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 90,
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_INSTANCE_HOST_PATTERN.name =>
        "?.#{proxy_info.instance_endpoint_suffix}:#{proxy_info.instance_endpoint_port}",
      connect_timeout: 10
    }
  end

  def failover_connect(host:, port:, props: {})
    config = Integration::DriverHelper.native_config(
      drv,
      host: host,
      port: port,
      user: proxy_info.username,
      password: proxy_info.password,
      dbname: proxy_info.default_dbname
    )
    conn = Integration::DriverHelper.wrapper_connect(drv, **config, **failover_props.merge(props))
    expect(wait_for_full_topology).to be(true), 'Topology was not fully discovered after establishing a connection'
    conn
  end

  # Waits until the topology cache holds an entry for every instance in the cluster, which indicates the
  # topology monitor has completed a full discovery through the cluster endpoint.
  def wait_for_full_topology(timeout_secs: 30, delay_secs: 0.5)
    expected_count = proxy_info.instances.size
    Integration::RetryHelper.retry_until(timeout_secs: timeout_secs, delay_secs: delay_secs) do
      hosts = AwsRubyDatabaseDriverWrapper::Services::CoreServices.storage_service.get(
        :topology,
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_ID.default_value,
        register_access: false
      )
      !hosts.nil? && hosts.size >= expected_count
    end
  end

  describe 'writer failover' do
    it 'fails over on connection invocation when writer dies',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = failover_connect(host: proxy_info.cluster_endpoint, port: proxy_info.cluster_endpoint_port)

      # This connection was established through the cluster endpoint proxy, which forwards to the writer
      # independently of the writer's instance proxy. Disabling only the instance proxy would leave this
      # path intact, so the connection would stay healthy and no failover would be triggered.
      Integration::ProxyHelper.disable_proxy(proxy_info.cluster_endpoint)
      rds_util.crash_instance(current_writer)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over on connection bound object invocation (mysql2 prepared statement)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::MYSQL] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)
      stmt = conn.prepare('SELECT 1')

      rds_util.crash_instance(current_writer)

      expect { stmt.execute }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over within transaction',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)

      Integration::DriverHelper.execute(drv, conn, 'DROP TABLE IF EXISTS test_failover_transaction')
      Integration::DriverHelper.execute(
        drv, conn, 'CREATE TABLE test_failover_transaction (id int not null primary key, val varchar(255) not null)'
      )
      Integration::DriverHelper.execute(drv, conn, 'BEGIN')
      Integration::DriverHelper.execute(drv, conn, "INSERT INTO test_failover_transaction VALUES (1, 'value1')")

      rds_util.crash_instance(current_writer)

      expect { Integration::DriverHelper.execute(drv, conn, "INSERT INTO test_failover_transaction VALUES (2, 'value2')") }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::TransactionStateUnknownError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true

      result = Integration::DriverHelper.execute(drv, conn, 'SELECT count(*) AS cnt FROM test_failover_transaction')
      count = result.first.is_a?(Hash) ? result.first.values.first : result.first[0]
      expect(count.to_i).to eq(0)

      Integration::DriverHelper.execute(drv, conn, 'DROP TABLE IF EXISTS test_failover_transaction')
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'reconnects to the same writer when original writer retains writer role after temporary failure',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      initial_id = initial_writer_instance.instance_id
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)

      rds_util.simulate_temporary_failure(current_writer, 0, 15)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
      expect(current_connection_id).to eq(initial_id)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'preserves connection properties after failover (pg application_name)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::PG] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        props: { 'application_name' => 'failover_props_test' }
      )
      expect(conn.conninfo_hash[:application_name]).to eq('failover_props_test')

      rds_util.crash_instance(current_writer)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      expect(conn.conninfo_hash[:application_name]).to eq('failover_props_test')
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'preserves connection properties after failover (mysql read_timeout)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::MYSQL] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        props: { read_timeout: 13 }
      )

      expect(conn.query_options[:read_timeout]).to eq(13)

      rds_util.crash_instance(current_writer)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      expect(conn.query_options[:read_timeout]).to eq(13)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'times out and raises FailoverFailedError when all instances are unreachable',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        props: { AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 30 }
      )

      Integration::ProxyHelper.disable_all_connectivity

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverFailedError
      )
    end

    it 'fails over concurrent connections when writer dies',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      connections = Array.new(3) do
        failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)
      end

      rds_util.crash_instance(current_writer)

      threads = connections.map do |conn|
        Thread.new do
          rds_util.query_instance_id(conn)
          { error: nil }
        rescue StandardError => e
          { error: e }
        end
      end

      results = threads.map(&:value)
      results.each do |result|
        expect(result[:error]).to be_a(AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError)
      end

      connections.each do |conn|
        current_connection_id = rds_util.query_instance_id(conn)
        expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
      end
    ensure
      connections.each { |conn| Integration::DriverHelper.close(drv, conn) if conn }
    end
  end

  describe 'reader failover' do
    it 'fails over from reader to writer when no other reader available',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2, max_instances: 2)

      reader_instance = proxy_info.instances[1]
      conn = failover_connect(host: reader_instance.host, port: reader_instance.port)

      Integration::ProxyHelper.disable_connectivity(reader_instance.instance_id)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(current_connection_id).to eq(current_writer)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over with reader_or_writer mode',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        props: { AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_MODE.name => 'reader_or_writer' }
      )

      Integration::ProxyHelper.disable_connectivity(current_writer)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over with strict_reader mode to a reader instance',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 3)

      conn = failover_connect(
        host: proxy_info.cluster_read_only_endpoint,
        port: proxy_info.cluster_read_only_endpoint_port,
        props: {
          AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_MODE.name => 'strict_reader',
          AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 600
        }
      )

      Integration::ProxyHelper.disable_connectivity(proxy_info.cluster_read_only_endpoint)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(rds_util.db_instance_writer?(current_connection_id)).to be false
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'reconnects to any instance in reader_or_writer mode when original writer retains writer role after temporary failure',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        props: { AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_MODE.name => 'reader_or_writer' }
      )

      rds_util.simulate_temporary_failure(current_writer, 0, 5)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      expect { rds_util.query_instance_id(conn) }.not_to raise_error
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end
end
