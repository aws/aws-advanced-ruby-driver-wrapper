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

require 'concurrent'
require 'securerandom'
require 'timeout'
require_relative 'integration_helper'
require_relative 'utils/custom_endpoint_test_helper'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/driver_helper'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_utils'
require 'aws_advanced_ruby_driver_wrapper'

ORCHESTRATOR_TIMEOUT_SEC = 600
START_LATCH_TIMEOUT_SEC  = 60
FINISH_LATCH_TIMEOUT_SEC = 300
POST_OBSERVATION_SEC     = 30
PRE_TRIGGER_DELAY_SEC    = 5

RSpec.describe 'CustomEndpoint', :integration, :custom_endpoint,
               deployments: [Integration::DatabaseEngineDeployment::AURORA],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::CustomEndpointObserverThreads

  let(:rds_util) { Integration::RdsTestUtility.utility }

  context 'failover' do
    before(:all) do
      env = Integration::TestEnvironment.current
      next if env.instances.size < 3

      @driver = env.allowed_test_drivers.first
      @rds_util = Integration::RdsTestUtility.utility
      @endpoint_id = "test-ce-#{SecureRandom.uuid[0..7]}"
      @info = env.database_info

      writer_instance_id = @rds_util.cluster_writer_instance_id
      @rds_util.create_custom_endpoint(@endpoint_id, env.cluster_name, [writer_instance_id])
      @endpoint_info = @rds_util.wait_until_custom_endpoint_available(@endpoint_id)

      @results = Integration::CustomEndpointResults.new
      @global  = Integration::CustomEndpointGlobalResults.new
      @stop    = Concurrent::AtomicBoolean.new(false)

      # 2 threads: executing thread + failover trigger thread
      start_latch  = Concurrent::CountDownLatch.new(2)
      finish_latch = Concurrent::CountDownLatch.new(2)

      pd = AwsAdvancedRubyDriverWrapper::PropertyDefinition
      conn_config = Integration::DriverHelper.native_config(
        @driver,
        host: @endpoint_info.endpoint,
        port: @info.cluster_endpoint_port,
        user: @info.username,
        password: @info.password,
        dbname: @info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint,failover',
        pd::FAILOVER_MODE.name => 'reader_or_writer',
        pd::CLUSTER_INSTANCE_HOST_PATTERN.name =>
          "?.#{@info.instance_endpoint_suffix}:#{@info.instance_endpoint_port}",
        connect_timeout: 10
      )

      threads = [
        build_custom_endpoint_executing_thread(
          driver: @driver, config: conn_config, rds_util: @rds_util,
          start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
          results: @results, global: @global
        ),
        build_failover_trigger_thread(
          rds_util: @rds_util, pre_trigger_delay_sec: PRE_TRIGGER_DELAY_SEC,
          start_latch: start_latch, finish_latch: finish_latch, global: @global
        )
      ]

      begin
        Timeout.timeout(ORCHESTRATOR_TIMEOUT_SEC) do
          Integration::TestUtils.logger.warn('CustomEndpoint: start latch timed out') unless start_latch.wait(START_LATCH_TIMEOUT_SEC)

          # Wait for the failover trigger thread to finish, then observe post-failover behavior
          Integration::TestUtils.logger.warn('CustomEndpoint: finish latch timed out') unless finish_latch.wait(FINISH_LATCH_TIMEOUT_SEC)

          sleep(POST_OBSERVATION_SEC)
        end
      rescue Timeout::Error
        @global.timed_out.make_true
      ensure
        @stop.make_true
        threads.each do |t|
          t.join(5)
          t.kill if t.alive?
        end
      end
    end

    after(:all) do
      @rds_util&.delete_custom_endpoint(@endpoint_id)
    end

    it 'completes without unhandled exceptions' do
      enable_on_num_instances(min_instances: 3)
      expect(@global.unhandled_exceptions).to be_empty,
                                              "Unhandled exceptions: #{@global.unhandled_exceptions.map do |e|
                                                "#{e.class}: #{e.message}"
                                              end.join('; ')}"
    end

    it 'does not exceed the orchestrator hard timeout' do
      enable_on_num_instances(min_instances: 3)
      expect(@global.timed_out?).to be(false)
    end

    it 'raises at least one FailoverSuccessError during failover' do
      enable_on_num_instances(min_instances: 3)
      expect(@results.failover_success_errors.size).to be >= 1,
                                                       'Expected at least one FailoverSuccessError but none were recorded. ' \
                                                       'The failover plugin should reconnect to a new host and raise FailoverSuccessError.'
    end

    it 'reconnects to a member of the custom endpoint after failover' do
      enable_on_num_instances(min_instances: 3)
      post_id = @global.post_failover_instance_id.get
      expect(post_id).not_to be_nil, 'No post-failover instance id was recorded — the executing thread may not have reconnected'
      expect(@endpoint_info.static_members).to include(post_id),
                                               "Post-failover instance '#{post_id} " \
                                               "is not in custom endpoint members #{@endpoint_info.static_members}"
    end

    it 'executes successfully after failover reconnect' do
      enable_on_num_instances(min_instances: 3)
      expect(@results.post_failover_execute_times).not_to be_empty,
                                                          'Expected successful queries after FailoverSuccessError but none were recorded'
    end

    it 'does not raise FailoverFailedError' do
      enable_on_num_instances(min_instances: 3)
      expect(@results.failover_failed_errors).to be_empty,
                                                 "FailoverFailedError raised #{@results.failover_failed_errors.size} times: " \
                                                 "#{@results.failover_failed_errors.map { |e| e[:message] }.join('; ')}"
    end

    it 'does not raise unexpected errors during execution' do
      enable_on_num_instances(min_instances: 3)
      # Filter out AwsError timeouts waiting for custom endpoint info — these are expected
      # transiently after failover when the monitor's cached info has expired and the monitor
      # hasn't refreshed yet. They resolve on the next query once the cache is repopulated.
      non_transient_errors = @results.unexpected_errors.reject do |e|
        e[:error_class] == 'AwsAdvancedRubyDriverWrapper::Errors::AwsError' &&
          e[:message].include?('timed out') && e[:message].include?('custom endpoint info')
      end
      expect(non_transient_errors).to be_empty,
                                      'Unexpected errors during execution: ' \
                                      "#{non_transient_errors.map { |e| "#{e[:error_class]}: #{e[:message]}" }.join('; ')}"
    end
  end

  context 'membership enforcement — dynamic endpoint changes' do
    before(:all) do
      env = Integration::TestEnvironment.current
      next if env.instances.size < 3

      @driver = env.allowed_test_drivers.first
      @rds_util = Integration::RdsTestUtility.utility
      @endpoint_id = "test-ce-dyn-#{SecureRandom.uuid[0..7]}"
      @info = env.database_info

      @writer_id = @rds_util.cluster_writer_instance_id
      @reader_id = @rds_util.cluster_reader_instance_ids.first

      # Start with only the writer in the endpoint
      @rds_util.create_custom_endpoint(@endpoint_id, env.cluster_name, [@writer_id])
      @endpoint_info = @rds_util.wait_until_custom_endpoint_available(@endpoint_id)
    end

    after(:all) do
      @rds_util&.delete_custom_endpoint(@endpoint_id)
    end

    it 'monitor picks up added member and failover lands on an endpoint member' do
      enable_on_num_instances(min_instances: 3)
      pd = AwsAdvancedRubyDriverWrapper::PropertyDefinition
      conn_config = Integration::DriverHelper.native_config(
        @driver,
        host: @endpoint_info.endpoint,
        port: @info.cluster_endpoint_port,
        user: @info.username,
        password: @info.password,
        dbname: @info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint,failover',
        pd::FAILOVER_MODE.name => 'reader_or_writer',
        pd::CLUSTER_INSTANCE_HOST_PATTERN.name =>
          "?.#{@info.instance_endpoint_suffix}:#{@info.instance_endpoint_port}",
        # Short expiration so the monitor re-creation path is also exercised during the sleep below
        pd::CUSTOM_ENDPOINT_MONITOR_EXPIRATION_MS.name => 30_000,
        connect_timeout: 10
      )

      conn = Integration::DriverHelper.wrapper_connect(@driver, **conn_config)
      initial_id = @rds_util.query_instance_id(conn)
      expect([@writer_id]).to include(initial_id)

      # Add the reader to the endpoint and wait for the AWS API + monitor to reflect the change
      @rds_util.modify_custom_endpoint(@endpoint_id, static_members: [@writer_id, @reader_id])
      @rds_util.wait_until_custom_endpoint_has_members(@endpoint_id, [@writer_id, @reader_id])
      sleep(35) # allow one full monitor poll cycle (default 30s) to pick up the change

      Thread.new { @rds_util.failover_cluster_and_wait_until_writer_changed }

      failover_success = RetryHelper.retry_until(timeout_secs: 120, delay_secs: 1) do
        @rds_util.query_instance_id(conn)
        false
      rescue AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
        true
      end
      expect(failover_success).to be(true), 'Expected FailoverSuccessError but it was never raised'

      post_id = @rds_util.query_instance_id(conn)
      expect([@writer_id, @reader_id]).to include(post_id),
                                          "Post-failover instance '#{post_id}' is not in the updated " \
                                          "endpoint members #{[@writer_id, @reader_id]}"
    ensure
      Integration::DriverHelper.close(@driver, conn) if conn
      # Revert endpoint back to writer-only so the cluster is clean for subsequent tests
      @rds_util&.modify_custom_endpoint(@endpoint_id, static_members: [@writer_id])
      @rds_util&.wait_until_custom_endpoint_has_members(@endpoint_id, [@writer_id])
    end

    it 'monitor picks up removed member and failover stays within remaining endpoint members' do
      enable_on_num_instances(min_instances: 3)
      pd = AwsAdvancedRubyDriverWrapper::PropertyDefinition
      conn_config = Integration::DriverHelper.native_config(
        @driver,
        host: @endpoint_info.endpoint,
        port: @info.cluster_endpoint_port,
        user: @info.username,
        password: @info.password,
        dbname: @info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint,failover',
        pd::FAILOVER_MODE.name => 'reader_or_writer',
        pd::CLUSTER_INSTANCE_HOST_PATTERN.name =>
          "?.#{@info.instance_endpoint_suffix}:#{@info.instance_endpoint_port}",
        connect_timeout: 10
      )

      # Start with both writer and reader in the endpoint
      @rds_util.modify_custom_endpoint(@endpoint_id, static_members: [@writer_id, @reader_id])
      @rds_util.wait_until_custom_endpoint_has_members(@endpoint_id, [@writer_id, @reader_id])
      sleep(35)

      conn = Integration::DriverHelper.wrapper_connect(@driver, **conn_config)

      # Remove the reader — only the writer remains
      @rds_util.modify_custom_endpoint(@endpoint_id, static_members: [@writer_id])
      @rds_util.wait_until_custom_endpoint_has_members(@endpoint_id, [@writer_id])
      sleep(35)

      Thread.new { @rds_util.failover_cluster_and_wait_until_writer_changed }

      failover_success = RetryHelper.retry_until(timeout_secs: 120, delay_secs: 1) do
        @rds_util.query_instance_id(conn)
        false
      rescue AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
        true
      end
      expect(failover_success).to be(true), 'Expected FailoverSuccessError but it was never raised'

      post_id = @rds_util.query_instance_id(conn)
      expect(post_id).to eq(@writer_id),
                         "Expected failover to land on the sole endpoint member '#{@writer_id}' " \
                         "but landed on '#{post_id}'"
    ensure
      Integration::DriverHelper.close(@driver, conn) if conn
      @rds_util&.modify_custom_endpoint(@endpoint_id, static_members: [@writer_id])
    end
  end

  context 'membership enforcement — non-member host filtered during failover' do
    before(:all) do
      env = Integration::TestEnvironment.current
      next if env.instances.size < 3

      @driver = env.allowed_test_drivers.first
      @rds_util = Integration::RdsTestUtility.utility
      @endpoint_id = "test-ce-flt-#{SecureRandom.uuid[0..7]}"
      @info = env.database_info

      # Pin the endpoint to exactly one reader — the writer and all other readers are non-members.
      # With 3+ instances this makes a random reconnect land on the allowed host only 1-in-N times
      # by chance, so a correct result is deterministic proof of enforcement.
      @writer_id    = @rds_util.cluster_writer_instance_id
      reader_ids    = @rds_util.cluster_reader_instance_ids
      @allowed_reader_id = reader_ids.first

      @rds_util.create_custom_endpoint(@endpoint_id, env.cluster_name, [@allowed_reader_id])
      @endpoint_info = @rds_util.wait_until_custom_endpoint_available(@endpoint_id)
    end

    after(:all) do
      @rds_util&.delete_custom_endpoint(@endpoint_id)
    end

    it 'failover reconnects only to the single allowed endpoint member, not the writer or other readers' do
      enable_on_num_instances(min_instances: 3)
      pd = AwsAdvancedRubyDriverWrapper::PropertyDefinition
      conn_config = Integration::DriverHelper.native_config(
        @driver,
        host: @endpoint_info.endpoint,
        port: @info.cluster_endpoint_port,
        user: @info.username,
        password: @info.password,
        dbname: @info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint,failover',
        pd::FAILOVER_MODE.name => 'reader_or_writer',
        pd::CLUSTER_INSTANCE_HOST_PATTERN.name =>
          "?.#{@info.instance_endpoint_suffix}:#{@info.instance_endpoint_port}",
        connect_timeout: 10
      )

      conn = Integration::DriverHelper.wrapper_connect(@driver, **conn_config)
      initial_id = @rds_util.query_instance_id(conn)
      expect(initial_id).to eq(@allowed_reader_id),
                            "Expected initial connection to the sole endpoint member '#{@allowed_reader_id}' " \
                            "but connected to '#{initial_id}'"

      # Fail over to the allowed reader specifically so its connection is disrupted.
      # A plain cluster failover only changes the writer, leaving reader connections alive.
      @rds_util.failover_cluster_and_wait_until_writer_changed(target_instance_id: @allowed_reader_id)

      expect { @rds_util.query_instance_id(conn) }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError
      )

      post_id = @rds_util.query_instance_id(conn)
      expect(post_id).to eq(@allowed_reader_id),
                         "Expected reconnect to the sole allowed member '#{@allowed_reader_id}' " \
                         "but landed on '#{post_id}' — non-member host was not filtered"
    ensure
      Integration::DriverHelper.close(@driver, conn) if conn
    end
  end

  context 'plugin behavior' do
    before(:all) do
      env = Integration::TestEnvironment.current
      next if env.allowed_test_drivers.empty?

      @pb_driver = env.allowed_test_drivers.first
      @pb_rds_util = Integration::RdsTestUtility.utility
      @pb_endpoint_id = "test-ce-pb-#{SecureRandom.uuid[0..7]}"
      @pb_info = env.database_info

      writer_instance_id = @pb_rds_util.cluster_writer_instance_id
      @pb_rds_util.create_custom_endpoint(@pb_endpoint_id, env.cluster_name, [writer_instance_id])
      @pb_endpoint_info = @pb_rds_util.wait_until_custom_endpoint_available(@pb_endpoint_id)
    end

    after(:all) do
      @pb_rds_util&.delete_custom_endpoint(@pb_endpoint_id)
    end

    before do
      skip 'No allowed drivers for this environment' if @pb_driver.nil?
    end

    let(:pd) { AwsAdvancedRubyDriverWrapper::PropertyDefinition }

    let(:base_custom_endpoint_props) do
      Integration::DriverHelper.native_config(
        @pb_driver,
        host: @pb_endpoint_info.endpoint,
        port: @pb_info.cluster_endpoint_port,
        user: @pb_info.username,
        password: @pb_info.password,
        dbname: @pb_info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint',
        pd::CLUSTER_INSTANCE_HOST_PATTERN.name =>
          "?.#{@pb_info.instance_endpoint_suffix}:#{@pb_info.instance_endpoint_port}",
        connect_timeout: 10
      )
    end

    it 'waitForCustomEndpointInfoTimeoutMs too short on cold cache raises AwsError' do
      fake_host = @pb_endpoint_info.endpoint.sub(/^[^.]+/, 'test-ce-nonexistent-fake')

      props = Integration::DriverHelper.native_config(
        @pb_driver,
        host: fake_host,
        port: @pb_info.cluster_endpoint_port,
        user: @pb_info.username,
        password: @pb_info.password,
        dbname: @pb_info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint',
        pd::WAIT_FOR_CUSTOM_ENDPOINT_INFO.name => true,
        pd::WAIT_FOR_CUSTOM_ENDPOINT_INFO_TIMEOUT_MS.name => 100,
        connect_timeout: 3
      )
      expect do
        conn = Integration::DriverHelper.wrapper_connect(@pb_driver, **props)
        Integration::DriverHelper.close(@pb_driver, conn)
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /timed out/i)
    end

    it 'waitForCustomEndpointInfoTimeoutMs long enough on cold cache — connection succeeds' do
      props = base_custom_endpoint_props.merge(
        pd::WAIT_FOR_CUSTOM_ENDPOINT_INFO.name => true,
        pd::WAIT_FOR_CUSTOM_ENDPOINT_INFO_TIMEOUT_MS.name => 5_000,
        pd::CLUSTER_ID.name => "custom-endpoint-wait-success-#{SecureRandom.uuid[0..7]}"
      )
      conn = nil
      expect { conn = Integration::DriverHelper.wrapper_connect(@pb_driver, **props) }.not_to raise_error
      expect(@pb_rds_util.query_instance_id(conn)).not_to be_nil
    ensure
      Integration::DriverHelper.close(@pb_driver, conn) if conn
    end

    it 'waitForCustomEndpointInfo=false on cold cache — connection succeeds without raising' do
      props = base_custom_endpoint_props.merge(
        pd::WAIT_FOR_CUSTOM_ENDPOINT_INFO.name => false,
        pd::CLUSTER_ID.name => "custom-endpoint-no-wait-test-#{SecureRandom.uuid[0..7]}"
      )
      conn = nil
      expect { conn = Integration::DriverHelper.wrapper_connect(@pb_driver, **props) }.not_to raise_error
    ensure
      Integration::DriverHelper.close(@pb_driver, conn) if conn
    end

    it 'non-custom-endpoint URL with customEndpoint plugin loaded connects normally' do
      writer_instance = @pb_info.instances.first
      props = Integration::DriverHelper.native_config(
        @pb_driver,
        host: writer_instance.host,
        port: writer_instance.port,
        user: @pb_info.username,
        password: @pb_info.password,
        dbname: @pb_info.default_dbname
      ).merge(
        pd::PLUGINS.name => 'custom_endpoint',
        connect_timeout: 10
      )

      conn = nil
      expect { conn = Integration::DriverHelper.wrapper_connect(@pb_driver, **props) }.not_to raise_error
      expect(@pb_rds_util.query_instance_id(conn)).not_to be_nil
    ensure
      Integration::DriverHelper.close(@pb_driver, conn) if conn
    end

    it 'monitor re-creation after expiry — connection after monitor expires re-fetches info and succeeds' do
      props = base_custom_endpoint_props.merge(
        pd::WAIT_FOR_CUSTOM_ENDPOINT_INFO.name => true,
        pd::CUSTOM_ENDPOINT_MONITOR_EXPIRATION_MS.name => 1_000
      )

      # First connection — warms the cache and starts the monitor
      conn = Integration::DriverHelper.wrapper_connect(@pb_driver, **props)
      Integration::DriverHelper.close(@pb_driver, conn)

      sleep(3)

      # Second connection — monitor has expired, must be re-created and re-fetch info
      conn2 = nil
      expect { conn2 = Integration::DriverHelper.wrapper_connect(@pb_driver, **props) }.not_to raise_error
    ensure
      Integration::DriverHelper.close(@pb_driver, conn2) if conn2
    end
  end
end
