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
require_relative 'utils/database_engine_deployment'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require 'securerandom'
require 'aws_advanced_ruby_driver_wrapper'

# GDB in-home failover integration suite: failover triggered purely by Toxiproxy connectivity
# manipulation on a proxied primary-region instance. No server-side failover happens here.
RSpec.describe 'GDB Failover', :integration,
               features: [Integration::TestEnvironmentFeatures::GLOBAL_DATABASE,
                          Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA_GLOBAL],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:drv)      { env.current_driver || env.allowed_test_drivers.first }

  # Home region = the GDB primary region (region A).
  let(:home_region) { env.primary_region }

  # The primary-region (region A) instances.
  let(:primary_db_info) { env.database_info }
  # Proxied primary-region instances (Toxiproxy).
  let(:proxy_db_info) { env.proxy_database_info }

  # The proxied instance that is *currently* the writer.
  let(:writer_instance) do
    writer_id = rds_util.cluster_writer_instance_id(env.cluster_name)
    proxy_db_info.instances.find { |i| i.instance_id == writer_id } ||
      raise("Writer #{writer_id} not found among proxied instances " \
            "#{proxy_db_info.instances.map(&:instance_id)}")
  end

  # A proxied instance that is *currently* a reader.
  let(:reader_instance) do
    reader_ids = rds_util.cluster_reader_instance_ids(env.cluster_name)
    proxy_db_info.instances.find { |i| reader_ids.include?(i.instance_id) } ||
      raise("No reader found among proxied instances #{proxy_db_info.instances.map(&:instance_id)} " \
            "(cluster readers #{reader_ids})")
  end

  let(:current_writer) { writer_instance.instance_id }

  # Restart-window (in seconds) the background thread waits before re-enabling connectivity, giving
  # the plugin time to observe the outage and fail over while the host is unreachable.
  let(:failure_duration_secs) { 15 }

  # Builds the gdb_failover wrapper props for a connection. A unique cluster_id per connection keeps
  # topology caches from being shared across connections. The two-region instance host patterns are
  # taken from the current environment so the plugin can classify each host's region.
  def gdb_props(in_home_mode:, out_of_home_mode: nil, accessible_regions: nil, extra_props: {})
    Integration::RdsTestUtility.gdb_wrapper_props(
      cluster_id: "gdb-#{SecureRandom.uuid}",
      home_region: home_region,
      in_home_mode: in_home_mode,
      out_of_home_mode: out_of_home_mode,
      accessible_regions: accessible_regions,
      instance_host_patterns: Integration::RdsTestUtility.global_proxy_instance_host_patterns,
      extra_props: {
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 90,
        connect_timeout: 10
      }.merge(extra_props)
    )
  end

  # Opens a wrapper connection through a primary-region instance endpoint and waits until the
  # topology is fully discovered, so the plugin has the complete two-region host list before a
  # trigger fires.
  def gdb_connect(instance:, props:)
    config = Integration::DriverHelper.native_config(
      drv,
      host: instance.host,
      port: instance.port,
      user: proxy_db_info.username,
      password: proxy_db_info.password,
      dbname: proxy_db_info.default_dbname
    )
    Integration::IntegrationHelper::LOGGER.info(
      "GDB connect: instance_id=#{instance.instance_id} host=#{instance.host}:#{instance.port} " \
      "(proxied=#{instance.host.include?('proxied')}) " \
      "host_patterns=#{props[AwsAdvancedRubyDriverWrapper::PropertyDefinition::GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS.name]}"
    )
    conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)
    cluster_id = props[AwsAdvancedRubyDriverWrapper::PropertyDefinition::CLUSTER_ID.name]
    expect(wait_for_full_topology(cluster_id: cluster_id)).to be(true),
                                                              'Topology was not fully discovered after establishing a connection'
    conn
  end

  # Waits until the topology cache holds an entry for every instance the plugin should discover
  # across both regions (region A + region B), indicating the topology monitor completed a full
  # discovery.
  def wait_for_full_topology(cluster_id:, timeout_secs: 60, delay_secs: 0.5)
    expected_count = primary_db_info.instances.size + env.secondary_instances.size
    Integration::RetryHelper.retry_until(timeout_secs: timeout_secs, delay_secs: delay_secs) do
      hosts = AwsAdvancedRubyDriverWrapper::Services::CoreServices.storage_service.get(
        :topology,
        cluster_id,
        register_access: false
      )
      !hosts.nil? && hosts.size >= expected_count
    end
  end

  describe 'writer failover' do
    # Writer failover on connection invocation (in_home = strict_writer).
    it 'fails over on connection invocation when writer connectivity is lost (strict_writer)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(instance: writer_instance, props: gdb_props(in_home_mode: 'strict_writer'))

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    # Writer failover on a connection-bound object (mysql2 prepared statement).
    it 'fails over on connection bound object invocation (mysql2 prepared statement)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::MYSQL] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(instance: writer_instance, props: gdb_props(in_home_mode: 'strict_writer'))
      stmt = conn.prepare('SELECT 1')

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

      expect { stmt.execute }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    # Failover within a transaction -> TransactionStateUnknownError, rolled back.
    it 'fails over within a transaction and rolls back',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(instance: writer_instance, props: gdb_props(in_home_mode: 'strict_writer'))

      Integration::DriverHelper.execute(drv, conn, 'DROP TABLE IF EXISTS test_gdb_failover_transaction')
      Integration::DriverHelper.execute(
        drv, conn, 'CREATE TABLE test_gdb_failover_transaction (id int not null primary key, val varchar(255) not null)'
      )
      Integration::DriverHelper.execute(drv, conn, 'BEGIN')
      Integration::DriverHelper.execute(drv, conn, "INSERT INTO test_gdb_failover_transaction VALUES (1, 'value1')")

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

      expect do
        Integration::DriverHelper.execute(drv, conn, "INSERT INTO test_gdb_failover_transaction VALUES (2, 'value2')")
      end.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::TransactionStateUnknownError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true

      result = Integration::DriverHelper.execute(drv, conn, 'SELECT count(*) AS cnt FROM test_gdb_failover_transaction')
      count = result.first.is_a?(Hash) ? result.first.values.first : result.first[0]
      expect(count.to_i).to eq(0)

      Integration::DriverHelper.execute(drv, conn, 'DROP TABLE IF EXISTS test_gdb_failover_transaction')
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    # All connectivity disabled -> FailoverFailedError within failover_timeout_sec.
    it 'raises FailoverFailedError when all connectivity is disabled',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(
        instance: writer_instance,
        props: gdb_props(
          in_home_mode: 'strict_writer',
          extra_props: { AwsAdvancedRubyDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 30 }
        )
      )

      Integration::ProxyHelper.disable_all_connectivity

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError
      )
    ensure
      Integration::ProxyHelper.enable_all_connectivity
      Integration::DriverHelper.close(drv, conn) if conn
    end

    # Concurrent connections all fail over (in_home = strict_writer).
    it 'fails over concurrent connections when writer connectivity is lost',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      connections = Array.new(3) do
        gdb_connect(instance: writer_instance, props: gdb_props(in_home_mode: 'strict_writer'))
      end

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

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
        expect(result[:error]).to be_a(AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError)
      end

      connections.each do |conn|
        current_connection_id = rds_util.query_instance_id(conn)
        expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
      end
    ensure
      connections&.each { |conn| Integration::DriverHelper.close(drv, conn) if conn }
    end
  end

  describe 'home_reader_or_writer failover' do
    # Reader -> another home-region member (home_reader_or_writer).
    # Connected to a region-A reader; disable it; the plugin falls back to another reachable
    # home-region member (the writer, or another home-region reader if one exists).
    it 'fails over from a home reader to another home-region member (home_reader_or_writer)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(instance: reader_instance, props: gdb_props(in_home_mode: 'home_reader_or_writer'))

      rds_util.simulate_temporary_failure(reader_instance.instance_id, 0, failure_duration_secs)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      # home_reader_or_writer permits either the writer or a home-region reader, so accept either
      # role rather than requiring the writer specifically but assert region explicitly.
      current_connection_id = rds_util.query_instance_id(conn)
      landed_region = rds_util.region_of_instance(current_connection_id)
      landed_role = rds_util.instance_role(current_connection_id, cluster_id: env.cluster_name)
      expect(landed_region).to(
        eq(:primary),
        'expected home_reader_or_writer to land on a region-A (:primary) member, ' \
        "landed on #{current_connection_id} (region #{landed_region.inspect}, role #{landed_role})"
      )
      expect(%i[writer reader]).to(
        include(landed_role),
        'expected home_reader_or_writer to land on a region-A writer or reader, ' \
        "landed on #{current_connection_id} (role #{landed_role})"
      )
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    # home_reader_or_writer mode failover triggered from the writer.
    it 'fails over from the writer to a home-region member (home_reader_or_writer)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(instance: writer_instance, props: gdb_props(in_home_mode: 'home_reader_or_writer'))

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      # home_reader_or_writer permits the writer or a home-region reader; assert region explicitly
      # and accept either role.
      current_connection_id = rds_util.query_instance_id(conn)
      landed_region = rds_util.region_of_instance(current_connection_id)
      landed_role = rds_util.instance_role(current_connection_id, cluster_id: env.cluster_name)
      expect(landed_region).to(
        eq(:primary),
        'expected home_reader_or_writer to land on a region-A (:primary) member, ' \
        "landed on #{current_connection_id} (region #{landed_region.inspect}, role #{landed_role})"
      )
      expect(%i[writer reader]).to(
        include(landed_role),
        'expected home_reader_or_writer to land on a region-A writer or reader, ' \
        "landed on #{current_connection_id} (role #{landed_role})"
      )
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  describe 'strict reader failover' do
    # strict_home_reader in-home from writer.
    it 'fails over with strict_home_reader mode to a home-region reader (constrained)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      # Connect to the writer and trigger on the writer, so the home-region reader (region A) remains
      # reachable as a strict_home_reader target.
      conn = gdb_connect(
        instance: writer_instance,
        props: gdb_props(
          in_home_mode: 'strict_home_reader',
          extra_props: { AwsAdvancedRubyDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 120 }
        )
      )

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      # The landed host must be a reader in the home region (region A).
      current_connection_id = rds_util.query_instance_id(conn)
      expect(rds_util.region_of_instance(current_connection_id)).to eq(:primary)
      expect(rds_util.instance_role(current_connection_id)).to eq(:reader)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    # strict_any_reader in-home from writer.
    it 'fails over with strict_any_reader mode to a reader in any region (constrained)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(
        instance: writer_instance,
        props: gdb_props(
          in_home_mode: 'strict_any_reader',
          extra_props: { AwsAdvancedRubyDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 120 }
        )
      )

      rds_util.simulate_temporary_failure(current_writer, 0, failure_duration_secs)

      expect { rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      # The landed host must be a reader (in either region).
      current_connection_id = rds_util.query_instance_id(conn)
      expect(rds_util.instance_role(current_connection_id, cluster_id: cluster_id_for(current_connection_id))).to eq(:reader)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  describe 'read-only-error failover' do
    # Read-only-error triggers failover when both modes are strict_writer.
    it 'triggers failover on a read-only error when both modes are strict_writer',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      conn = gdb_connect(
        instance: reader_instance,
        props: gdb_props(in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer')
      )

      expect { execute_write_probe(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = rds_util.query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true

      execute_drop_probe(conn)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  def cluster_id_for(instance_id)
    rds_util.region_of_instance(instance_id) == :secondary ? env.secondary_cluster_identifier : env.cluster_name
  end

  def execute_write_probe(conn)
    Integration::DriverHelper.execute(drv, conn, 'CREATE TABLE IF NOT EXISTS test_gdb_read_only_probe (id int)')
  end

  def execute_drop_probe(conn)
    Integration::DriverHelper.execute(drv, conn, 'DROP TABLE IF EXISTS test_gdb_read_only_probe')
  end
end
