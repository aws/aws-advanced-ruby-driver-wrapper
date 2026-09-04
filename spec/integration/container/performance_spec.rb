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

require 'aws_advanced_ruby_driver_wrapper'
require 'concurrent'
require 'fileutils'
require_relative 'integration_helper'
require_relative 'utils/perf_stat'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/driver_helper'
require_relative 'utils/proxy_helper'
require_relative 'utils/rds_test_utility'

PERF_REPEAT_TIMES          = ENV.fetch('REPEAT_TIMES', '5').to_i
PERF_INTER_ITERATION_SLEEP = ENV.fetch('INTER_ITERATION_SLEEP', '15').to_i
PERF_FINISH_LATCH_TIMEOUT  = 120
PERF_RECONNECT_TIMEOUT_SEC = 5
PERF_SOCKET_TIMEOUT_PARAMS = [[30, 10_000], [30, 20_000], [30, 30_000]].freeze

RSpec.describe 'Failover Performance', :integration,
               features: [Integration::TestEnvironmentFeatures::PERFORMANCE,
                          Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED,
                          Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA,
                             Integration::DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER],
               disable_on_features: [Integration::TestEnvironmentFeatures::BLUE_GREEN_DEPLOYMENT],
               order: :defined do
  before(:all) do
    @env    = Integration::TestEnvironment.current
    @driver = @env.allowed_test_drivers.first
    @socket_timeout_stats = []
    @unhandled_exceptions = Concurrent::Array.new
    Integration::ProxyHelper.enable_all_connectivity
  end

  before(:each) do
    @unhandled_exceptions ||= Concurrent::Array.new
  end

  after(:all) do
    Integration::ProxyHelper.enable_all_connectivity
    write_csv('FailoverSocketTimeout', Integration::PerfStat, @socket_timeout_stats)
  end

  PERF_SOCKET_TIMEOUT_PARAMS.each do |timeout_sec, outage_delay_ms|
    it "socket_timeout timeout=#{timeout_sec}s outage=#{outage_delay_ms}ms" do
      run_param_set(timeout_sec, outage_delay_ms)
      assert_no_unhandled_exceptions
      stat = @socket_timeout_stats.last
      expect(stat).not_to be_nil, 'No perf stats collected'
      expect(stat.min_ms).to be > 0
    end
  end

  private

  def proxy_info
    @env.proxy_database_info
  end

  def native_config
    Integration::DriverHelper.native_config(
      @driver,
      host: proxy_info.cluster_endpoint,
      port: proxy_info.cluster_endpoint_port,
      user: proxy_info.username,
      password: proxy_info.password,
      dbname: proxy_info.default_dbname
    )
  end

  def wrapper_props(timeout_sec)
    {
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::PLUGINS.name => 'failover',
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 300,
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_INSTANCE_HOST_PATTERN.name =>
        "?.#{proxy_info.instance_endpoint_suffix}:#{proxy_info.instance_endpoint_port}",
      connect_timeout: PERF_RECONNECT_TIMEOUT_SEC,
      **driver_timeout_props(timeout_sec)
    }
  end

  def driver_timeout_props(timeout_sec)
    case @driver
    when Integration::TestDriver::PG
      { keepalives: 1, keepalives_idle: timeout_sec, keepalives_interval: 1, keepalives_count: 1 }
    when Integration::TestDriver::MYSQL
      { read_timeout: timeout_sec }
    else {}
    end
  end

  def open_wrapper_with_retry(config, props, max_retries: 10)
    retries = 0
    loop do
      return Integration::DriverHelper.wrapper_connect(@driver, **config, **props)
    rescue StandardError => e
      retries += 1
      raise e if retries >= max_retries

      sleep(1)
    end
  end

  def safe_close(conn)
    return if conn.nil?

    Integration::DriverHelper.close(@driver, conn)
  rescue StandardError
    # ignore
  end

  def sleep_query
    Integration::RdsTestUtility.sleep_sql.call(600)
  end

  def build_trigger_thread(outage_delay_ms:, instance_id:, downtime_at:, start_latch:, finish_latch:)
    Thread.new do
      Thread.current.name = 'PerfTrigger'
      begin
        start_latch.count_down
        start_latch.wait(60)

        sleep(outage_delay_ms / 1000.0)
        Integration::ProxyHelper.disable_connectivity(instance_id)
        downtime_at.set(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      rescue StandardError => e
        @unhandled_exceptions << e
      ensure
        finish_latch.count_down
      end
    end
  end

  def build_measurement_thread(config:, props:, downtime_at:, elapsed_times:, start_latch:, finish_latch:)
    Thread.new do
      Thread.current.name = 'PerfMeasurement'
      conn = nil
      begin
        conn = open_wrapper_with_retry(config, props)
        Thread.current[:perf_conn] = conn
        start_latch.count_down
        start_latch.wait(60)

        Integration::DriverHelper.execute(@driver, conn, sleep_query)
      rescue StandardError => e
        down_at = downtime_at.get
        if down_at.positive?
          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - down_at) * 1000
          elapsed_times << elapsed_ms
        else
          @unhandled_exceptions << e
        end
      ensure
        Thread.current[:perf_conn] = nil
        safe_close(conn)
        Integration::ProxyHelper.enable_all_connectivity
        finish_latch.count_down
      end
    end
  end

  def run_param_set(timeout_sec, outage_delay_ms)
    elapsed_times    = []
    cluster_endpoint = proxy_info.cluster_endpoint
    config           = native_config
    props            = wrapper_props(timeout_sec)

    PERF_REPEAT_TIMES.times do
      Integration::ProxyHelper.restore_connectivity(cluster_endpoint)
      Integration::ProxyHelper.enable_all_connectivity
      sleep(PERF_INTER_ITERATION_SLEEP)

      downtime_at  = Concurrent::AtomicReference.new(0.0)
      start_latch  = Concurrent::CountDownLatch.new(2)
      finish_latch = Concurrent::CountDownLatch.new(2)

      threads = [
        build_trigger_thread(
          outage_delay_ms: outage_delay_ms, instance_id: cluster_endpoint,
          downtime_at: downtime_at, start_latch: start_latch, finish_latch: finish_latch
        ),
        build_measurement_thread(
          config: config, props: props, downtime_at: downtime_at,
          elapsed_times: elapsed_times, start_latch: start_latch, finish_latch: finish_latch
        )
      ]

      finish_latch.wait(PERF_FINISH_LATCH_TIMEOUT)
      threads.each do |t|
        next unless t.alive?

        cancel_connection(t[:perf_conn])
        t.join(10)
        t.kill if t.alive?
      end
    end

    return if elapsed_times.empty?

    min = elapsed_times.min.round
    max = elapsed_times.max.round
    avg = (elapsed_times.sum / elapsed_times.size).round
    @socket_timeout_stats << Integration::PerfStat.new(timeout_sec, outage_delay_ms, min, max, avg)
  end

  def cancel_connection(conn)
    return if conn.nil?

    case @driver
    when Integration::TestDriver::PG
      raw = conn.respond_to?(:raw_connection) ? conn.raw_connection : conn
      raw.cancel if raw.respond_to?(:cancel)
    when Integration::TestDriver::MYSQL
      safe_close(conn)
    end
  rescue StandardError
    # ignore
  end

  def assert_no_unhandled_exceptions
    expect(@unhandled_exceptions).to be_empty,
                                     lambda {
                                       "Unhandled exceptions: #{@unhandled_exceptions.map { |e|
                                         "#{e.class}: #{e.message}"
                                       }.join('; ')}"
                                     }
  end

  def write_csv(label, stat_class, stats)
    return if stats.empty?

    path = format(
      'spec/integration/container/reports/%<label>s_Db_%<engine>s_Driver_%<driver>s_Instances_%<instances>d.csv',
      label: label,
      engine: @env.engine,
      driver: @driver,
      instances: @env.num_of_instances
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'w') do |f|
      f.puts stat_class.csv_header
      stats.each { |s| f.puts s.to_csv_row }
    end
  end
end
