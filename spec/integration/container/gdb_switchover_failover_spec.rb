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
require_relative 'utils/connection_utils'
require_relative 'utils/database_engine'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require 'securerandom'
require 'aws-sdk-secretsmanager'
require 'aws_ruby_database_driver_wrapper'

RSpec.describe 'GDB Switchover Failover', :integration,
               features: [Integration::TestEnvironmentFeatures::GLOBAL_DATABASE,
                          Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA_GLOBAL],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:drv)      { env.current_driver || env.allowed_test_drivers.first }

  # Home region = the GDB primary region (region A).
  let(:home_region) { env.primary_region }

  # Primary-region (region A) direct-endpoint instances.
  let(:primary_db_info) { env.database_info }

  # The region-A instance that is *currently* the writer.
  let(:writer_instance) do
    writer_id = rds_util.cluster_writer_instance_id(env.cluster_name)
    primary_db_info.instances.find { |i| i.instance_id == writer_id } ||
      raise("Region-A writer #{writer_id} not found among known instances " \
            "#{primary_db_info.instances.map(&:instance_id)}")
  end

  # Generous budget for a real cross-region transition to be observed on the live connection.
  let(:failover_timeout_sec) { 300 }

  # Each connection uses a unique cluster_id so topology caches are not shared, and the host patterns
  # so the plugin can classify each host's region and reconnect across the boundary after the switchover.
  def gdb_props(in_home_mode:, out_of_home_mode:, accessible_regions: nil, extra_props: {})
    Integration::RdsTestUtility.gdb_wrapper_props(
      cluster_id: "gdb-#{SecureRandom.uuid}",
      home_region: home_region,
      in_home_mode: in_home_mode,
      out_of_home_mode: out_of_home_mode,
      accessible_regions: accessible_regions,
      instance_host_patterns: Integration::RdsTestUtility.global_instance_host_patterns,
      extra_props: {
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => failover_timeout_sec,
        connect_timeout: 10
      }.merge(extra_props)
    )
  end

  def scenario_connect(scenario, instance:, db_info:, sm_secret_id: nil)
    pd = AwsRubyDatabaseDriverWrapper::PropertyDefinition
    case scenario.auth
    when :iam
      props = gdb_props(**scenario.props_args,
                        extra_props: { pd::PLUGINS.name => 'gdb_failover,iam' })
      gdb_connect(instance: instance, props: props, db_info: db_info,
                  user: env.iam_user_name, password: nil, require_ssl: true)
    when :secrets_manager
      props = gdb_props(**scenario.props_args,
                        extra_props: {
                          pd::PLUGINS.name => 'gdb_failover,secrets_manager',
                          pd::SECRET_ID.name => sm_secret_id,
                          pd::SECRET_REGION.name => env.primary_region
                        })
      # The secrets_manager plugin replaces these throwaway credentials with the fetched secret.
      gdb_connect(instance: instance, props: props, db_info: db_info, user: 'ignored', password: 'ignored')
    else
      gdb_connect(instance: instance, props: gdb_props(**scenario.props_args), db_info: db_info)
    end
  end

  def create_sm_secret_if_needed(scenarios, db_info)
    return [nil, nil] unless scenarios.any? { |s| s.auth == :secrets_manager }

    client = Aws::SecretsManager::Client.new(region: env.primary_region)
    secret_id = "aws-ruby-wrapper-gdb-switchover-sm-#{SecureRandom.uuid}"
    client.create_secret(
      name: secret_id,
      secret_string: JSON.generate(username: db_info.username, password: db_info.password)
    )
    [client, secret_id]
  end

  def gdb_connect(instance:, props:, db_info: primary_db_info, user: nil, password: nil, require_ssl: false)
    config = Integration::DriverHelper.native_config(
      drv,
      host: instance.host,
      port: instance.port,
      user: user || db_info.username,
      password: password.nil? ? db_info.password : password,
      dbname: db_info.default_dbname
    )
    if require_ssl
      config = case drv
               when Integration::TestDriver::PG then config.merge(sslmode: 'require')
               when Integration::TestDriver::MYSQL then config.merge(ssl_mode: :required)
               else config
               end
    end
    dialect_code = if drv == Integration::TestDriver::PG
                     AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG
                   else
                     AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL
                   end
    config = config.merge(AwsRubyDatabaseDriverWrapper::PropertyDefinition::DIALECT.name => dialect_code)
    Integration::IntegrationHelper::LOGGER.info(
      "GDB connect: instance_id=#{instance.instance_id} host=#{instance.host}:#{instance.port} " \
      "home_region=#{home_region} " \
      "host_patterns=#{props[AwsRubyDatabaseDriverWrapper::PropertyDefinition::GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS.name]}"
    )
    conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)
    cluster_id = props[AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_ID.name]
    expect(wait_for_full_topology(cluster_id: cluster_id)).to be(true),
                                                              'Topology was not fully discovered after establishing a connection'
    conn
  end

  # Waits until the topology cache holds an entry for every instance the plugin should discover
  # across both regions, indicating the topology monitor completed a full discovery. The topology
  # cache is keyed by the connection's cluster_id.
  def wait_for_full_topology(cluster_id:, timeout_secs: 60, delay_secs: 0.5)
    expected_count = primary_db_info.instances.size + env.secondary_instances.size
    Integration::RetryHelper.retry_until(timeout_secs: timeout_secs, delay_secs: delay_secs) do
      hosts = AwsRubyDatabaseDriverWrapper::Services::CoreServices.storage_service.get(
        :topology,
        cluster_id,
        register_access: false
      )
      !hosts.nil? && hosts.size >= expected_count
    end
  end

  # Triggers the planned switchover A -> B on a background thread so the main thread can keep
  # querying the connection and observe the failover *mid-flight*. Returns the thread; the caller
  # is responsible for joining it (and surfacing any error it captured) after the observation.
  def start_switchover_async(target_cluster_id)
    Thread.new do
      rds_util.switchover_global_cluster(target_cluster_id)
    rescue StandardError => e
      Integration::IntegrationHelper::LOGGER.error("Switchover thread failed: #{e.class}: #{e.message}")
      raise
    end
  end

  # Drives one live connection in its own thread while the switchover runs in the background, until
  # the plugin surfaces a terminal failover outcome (FailoverSuccessError for connections that
  # reconnect, or FailoverFailedError for the accessible-region-restricted case), or the timeout
  # elapses. Captures the outcome so the caller can aggregate assertions after all threads finish.
  # On a successful failover it also records the settled instance id.
  #
  # @return [Hash] { outcome: :success|:failed|:timeout, error: <exception or nil>, landed_id: <id or nil> }
  def drive_until_terminal(conn, timeout_secs:)
    deadline = Time.now + timeout_secs
    loop do
      begin
        rds_util.query_instance_id(conn)
      rescue AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError => e
        return { outcome: :success, error: e, landed_id: settled_instance_id(conn, deadline: deadline) }
      rescue AwsRubyDatabaseDriverWrapper::Errors::FailoverFailedError => e
        return { outcome: :failed, error: e, landed_id: nil }
      end
      return { outcome: :timeout, error: nil, landed_id: nil } if Time.now > deadline

      sleep(1)
    end
  end

  # Reads the instance id of the connection after a failover signal has been observed, tolerating a
  # single follow-up FailoverSuccessError. Retries until a real id is returned or the deadline passes.
  def settled_instance_id(conn, deadline:)
    loop do
      return rds_util.query_instance_id(conn)
    rescue AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      return nil if Time.now > deadline

      sleep(1)
    end
  end

  # The region-B instance that is *currently* the writer.
  def current_secondary_writer_instance
    writer_id = Integration::RdsTestUtility.secondary_utility
                                           .cluster_writer_instance_id(env.secondary_cluster_identifier)
    env.secondary_instances.find { |i| i.instance_id == writer_id } ||
      raise("Region-B writer #{writer_id} not found among known secondary instances " \
            "#{env.secondary_instances.map(&:instance_id)}")
  end

  # A scenario: a distinct connection + mode config, plus a matcher describing the  outcome and (for
  # reconnecting scenarios) the set of `[region, role]` pairs the connection is allowed to land on.
  Scenario = Struct.new(
    :id, :description, :props_args, :expected_outcome, :allowed, :auth
  )

  # GDB out-of-home scenario matrix, all across the single A->B planned switchover. Home region = A,
  # so after the switchover the primary is out-of-home and each connection's out_of_home_failover_mode
  # governs target selection. Post-switchover topology: primary = B (writer B1 + reader B2), secondary
  # region A = readers A1, A2.
  def out_of_home_scenarios
    [
      # A1: strict_writer -> follows the writer into region B.
      Scenario.new(
        id: 'A1', description: 'out_of_home strict_writer -> writer in region B',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[secondary writer]]
      ),
      # A1-iam: strict_writer with IAM authentication -> follows the writer into region B.
      Scenario.new(
        id: 'A1-iam', description: 'out_of_home strict_writer (IAM auth) -> writer in region B',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[secondary writer]], auth: :iam
      ),
      # A1-sm: strict_writer with Secrets Manager credentials -> follows the writer into region B.
      Scenario.new(
        id: 'A1-sm', description: 'out_of_home strict_writer (Secrets Manager auth) -> writer in region B',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[secondary writer]], auth: :secrets_manager
      ),
      # A2: strict_home_reader -> a reader in home region A (A1/A2).
      Scenario.new(
        id: 'A2', description: 'out_of_home strict_home_reader -> reader in home region A',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_home_reader' },
        expected_outcome: :success, allowed: [%i[primary reader]]
      ),
      # A3: strict_out_of_home_reader -> a non-home reader; lands on B2.
      Scenario.new(
        id: 'A3', description: 'out_of_home strict_out_of_home_reader -> reader in region B',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_out_of_home_reader' },
        expected_outcome: :success, allowed: [%i[secondary reader]]
      ),
      # A4: strict_any_reader -> any reader across regions (A1/A2/B2), never the writer.
      Scenario.new(
        id: 'A4', description: 'out_of_home strict_any_reader -> any reader',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_any_reader' },
        expected_outcome: :success, allowed: [%i[primary reader], %i[secondary reader]]
      ),
      # A5: home_reader_or_writer -> the writer (B1) OR a home-region (A) reader. NOT the region-B
      # reader (B2): a home-biased non-strict mode keeps reads in the home region.
      Scenario.new(
        id: 'A5', description: 'out_of_home home_reader_or_writer -> writer (B) or home-region (A) reader',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'home_reader_or_writer' },
        expected_outcome: :success, allowed: [%i[secondary writer], %i[primary reader]]
      ),
      # A6: out_of_home_reader_or_writer -> the writer (B1) OR an out-of-home (B) reader (B2). NOT a
      # home-region (A) reader: an out-of-home-biased non-strict mode keeps reads out of home.
      Scenario.new(
        id: 'A6', description: 'out_of_home out_of_home_reader_or_writer -> writer (B) or out-of-home (B) reader',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'out_of_home_reader_or_writer' },
        expected_outcome: :success, allowed: [%i[secondary writer], %i[secondary reader]]
      ),
      # A7: any_reader_or_writer -> any reachable host in either region, either role.
      Scenario.new(
        id: 'A7', description: 'out_of_home any_reader_or_writer -> any host',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'any_reader_or_writer' },
        expected_outcome: :success,
        allowed: [%i[primary reader], %i[primary writer], %i[secondary reader], %i[secondary writer]]
      ),
      # A8: accessible_regions=[A] + strict_writer -> writer moves to non-accessible B -> fails.
      Scenario.new(
        id: 'A8', description: 'accessible_regions=[A] + out_of_home strict_writer -> FailoverFailedError',
        props_args: {
          in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer',
          accessible_regions: [home_region]
        },
        expected_outcome: :failed, allowed: nil
      )
    ]
  end

  # Asserts a reconnecting scenario landed on an instance whose [region, role] is in the scenario's
  # allowed set.
  def assert_landed_target(scenario, landed_id)
    expect(landed_id).not_to(
      be_nil,
      "#{scenario.id} (#{scenario.description}): failover succeeded but no settled instance id was captured"
    )
    landed_region = rds_util.region_of_instance(landed_id)
    # Classify the landed role against the cluster that owns the landed region. This is
    # direction-independent: a secondary-region host is always classified against the secondary
    # cluster identifier regardless of which way the planned transition ran (A->B or B->A).
    cluster_for_role = landed_region == :secondary ? env.secondary_cluster_identifier : env.cluster_name
    landed_role = rds_util.instance_role(landed_id, cluster_id: cluster_for_role)
    landed = [landed_region, landed_role]
    Integration::IntegrationHelper::LOGGER.info(
      "#{scenario.id} landed on instance_id=#{landed_id} region=#{landed_region} role=#{landed_role}"
    )

    expect(scenario.allowed).to(
      include(landed),
      "#{scenario.id} (#{scenario.description}): landed on #{landed_id} #{landed.inspect}, " \
      "allowed #{scenario.allowed.inspect}"
    )
  end

  # Drives one connection with an open transaction across the transition. An open transaction
  # interrupted by the switchover must surface TransactionStateUnknownError (not FailoverSuccessError)
  # on the next statement, proving the transaction is not silently committed. After that, it records
  # the settled instance id (captured here in the driver, tolerating a follow-up FailoverSuccessError)
  # so the caller can classify the recovery target without racing an in-progress reconnect.
  #
  # @return [Hash] { outcome: :txn_unknown|:timeout, error: <exception or nil>, landed_id: <id or nil> }
  def drive_txn_until_terminal(conn, timeout_secs:)
    deadline = Time.now + timeout_secs
    loop do
      begin
        rds_util.query_instance_id(conn)
      rescue AwsRubyDatabaseDriverWrapper::Errors::TransactionStateUnknownError => e
        return { outcome: :txn_unknown, error: e, landed_id: settled_instance_id(conn, deadline: deadline) }
      end
      return { outcome: :timeout, error: nil, landed_id: nil } if Time.now > deadline

      sleep(1)
    end
  end

  # Table used by the optional open-transaction scenario. Created on the source writer before the
  # transition and dropped (best-effort) during teardown.
  TXN_TABLE = 'test_gdb_transition_txn'

  # Shared driver for a single planned cross-region switchover, opens N multiplexed connections through
  # the current-primary writer, triggers one planned switchover on a background thread, drives every
  # connection concurrently so each observes the transition mid-flight, then aggregates each scenario's
  # [region, role] landing against its allowed set.
  #
  # @param from_writer_instance [TestInstanceInfo] the current-primary writer to connect through
  # @param from_db_info [Object] credentials for the region the source writer is in (A or B)
  # @param target_cluster_id [String] the cluster to switch the global primary TO
  # @param scenarios [Array<Scenario>] the reconnecting scenarios (one connection each)
  # @param aggregate_label [String] label for the aggregate_failures block
  # @param txn_scenario [Scenario, nil] optional open-transaction data-integrity scenario
  def run_planned_transition(from_writer_instance:, from_db_info:, target_cluster_id:,
                             scenarios:, aggregate_label:, txn_scenario: nil)
    conns = {}
    threads = {}
    results = {}
    txn_conn = nil

    # Create a Secrets Manager secret up front if any scenario authenticates via secrets_manager.
    sm_client, sm_secret_id = create_sm_secret_if_needed(scenarios, from_db_info)

    # Open every reconnecting connection through the current-primary writer and confirm full
    # two-region topology discovery before the switchover. Each scenario's auth (password/IAM/SM)
    # is applied here.
    scenarios.each do |scenario|
      conns[scenario.id] = scenario_connect(
        scenario,
        instance: from_writer_instance,
        db_info: from_db_info,
        sm_secret_id: sm_secret_id
      )
    end

    # Optional: a dedicated connection carrying an open transaction across the transition.
    if txn_scenario
      txn_conn = gdb_connect(
        instance: from_writer_instance,
        props: gdb_props(**txn_scenario.props_args),
        db_info: from_db_info
      )
      Integration::DriverHelper.execute(drv, txn_conn, "DROP TABLE IF EXISTS #{TXN_TABLE}")
      Integration::DriverHelper.execute(
        drv, txn_conn, "CREATE TABLE #{TXN_TABLE} (id int not null primary key, val varchar(255) not null)"
      )
      Integration::DriverHelper.execute(drv, txn_conn, 'BEGIN')
      Integration::DriverHelper.execute(drv, txn_conn, "INSERT INTO #{TXN_TABLE} VALUES (1, 'value1')")
    end

    # Trigger the single, real, planned switchover on a background thread, then drive every
    # connection concurrently so each observes the transition mid-flight (live/observing).
    switchover_thread = start_switchover_async(target_cluster_id)

    scenarios.each do |scenario|
      threads[scenario.id] = Thread.new do
        drive_until_terminal(conns[scenario.id], timeout_secs: failover_timeout_sec)
      end
    end
    txn_thread = Thread.new { drive_txn_until_terminal(txn_conn, timeout_secs: failover_timeout_sec) } if txn_scenario

    threads.each { |id, t| results[id] = t.value }
    txn_result = txn_thread&.value

    # Ensure the server-side switchover fully settled (target is primary) and surface any thread error.
    switchover_thread.join

    aggregate_failures aggregate_label do
      scenarios.each do |scenario|
        result = results[scenario.id]
        expect(result[:outcome]).to(
          eq(scenario.expected_outcome),
          "#{scenario.id} (#{scenario.description}): expected #{scenario.expected_outcome}, " \
          "got #{result[:outcome]} (#{result[:error]&.class})"
        )
        # Verify each landed on a target consistent with its mode.
        assert_landed_target(scenario, result[:landed_id]) if result[:outcome] == :success
      end

      assert_txn_scenario(txn_scenario, txn_result) if txn_scenario
    end
  ensure
    switchover_thread&.join
    tolerate_cleanup_error { Integration::DriverHelper.execute(drv, txn_conn, "DROP TABLE IF EXISTS #{TXN_TABLE}") } if txn_conn
    conns.each_value { |c| tolerate_cleanup_error { Integration::DriverHelper.close(drv, c) } }
    tolerate_cleanup_error { Integration::DriverHelper.close(drv, txn_conn) } if txn_conn
    if sm_client && sm_secret_id
      tolerate_cleanup_error do
        sm_client.delete_secret(secret_id: sm_secret_id, force_delete_without_recovery: true)
      end
    end
  end

  # Asserts the open-transaction scenario surfaced TransactionStateUnknownError and then recovered
  # onto an allowed [region, role] target.
  def assert_txn_scenario(txn_scenario, txn_result)
    expect(txn_result[:outcome]).to(
      eq(:txn_unknown),
      "#{txn_scenario.id} (#{txn_scenario.description}): expected :txn_unknown, " \
      "got #{txn_result[:outcome]} (#{txn_result[:error]&.class})"
    )
    return unless txn_result[:outcome] == :txn_unknown

    assert_landed_target(txn_scenario, txn_result[:landed_id])
  end

  def tolerate_cleanup_error
    yield
  rescue StandardError => e
    Integration::IntegrationHelper::LOGGER.warn("GDB transition cleanup ignored error: #{e.class}: #{e.message}")
  end

  describe 'out-of-home failover across a planned switchover A->B (multiplexed)' do
    it 'each connection resolves out_of_home mode from the new primary region and reconnects accordingly' do
      run_planned_transition(
        from_writer_instance: writer_instance,
        from_db_info: primary_db_info,
        target_cluster_id: env.secondary_cluster_identifier,
        scenarios: out_of_home_scenarios,
        aggregate_label: 'gdb switchover outcomes'
      )
    end
  end

  describe 'in-home failover across a planned switchover B->A (multiplexed)' do
    # Runs after switchover A->B, which left the primary in region B. A planned switchover B->A (failback)
    # returns the primary home to region A while leaving region B intact as a healthy secondary.
    it 'each connection resolves in_home mode from the home-region primary after a planned failback' do
      run_planned_transition(
        from_writer_instance: current_secondary_writer_instance,
        from_db_info: env.secondary_database_info,
        target_cluster_id: env.cluster_name,
        scenarios: in_home_scenarios,
        aggregate_label: 'gdb failback outcomes',
        txn_scenario: in_home_strict_writer_txn
      )
    end
  end

  # GDB in-home scenario matrix, all across the single B->A planned switchover (failback).
  def in_home_scenarios
    [
      # B1: strict_writer -> follows the writer back to the home region A.
      Scenario.new(
        id: 'B1', description: 'in_home strict_writer -> writer in home region A',
        props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[primary writer]]
      ),
      # B2: strict_home_reader -> a reader in home region A (A2).
      Scenario.new(
        id: 'B2', description: 'in_home strict_home_reader -> reader in home region A',
        props_args: { in_home_mode: 'strict_home_reader', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[primary reader]]
      ),
      # B3: strict_out_of_home_reader -> a non-home reader in region B (B1/B2).
      Scenario.new(
        id: 'B3', description: 'in_home strict_out_of_home_reader -> reader in region B',
        props_args: { in_home_mode: 'strict_out_of_home_reader', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[secondary reader]]
      ),
      # B4: strict_any_reader -> any reader across regions (A2/B1/B2), never the writer.
      Scenario.new(
        id: 'B4', description: 'in_home strict_any_reader -> any reader',
        props_args: { in_home_mode: 'strict_any_reader', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[primary reader], %i[secondary reader]]
      ),
      # B5: home_reader_or_writer -> the writer (A1) OR a home-region (A) reader (A2).
      Scenario.new(
        id: 'B5', description: 'in_home home_reader_or_writer -> writer (A) or home-region (A) reader',
        props_args: { in_home_mode: 'home_reader_or_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[primary writer], %i[primary reader]]
      ),
      # B6: out_of_home_reader_or_writer -> the writer (A1) OR an out-of-home (B) reader (B1/B2).
      Scenario.new(
        id: 'B6', description: 'in_home out_of_home_reader_or_writer -> writer (A) or out-of-home (B) reader',
        props_args: { in_home_mode: 'out_of_home_reader_or_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success, allowed: [%i[primary writer], %i[secondary reader]]
      ),
      # B7: any_reader_or_writer -> any reachable host in either region, either role.
      Scenario.new(
        id: 'B7', description: 'in_home any_reader_or_writer -> any host',
        props_args: { in_home_mode: 'any_reader_or_writer', out_of_home_mode: 'strict_writer' },
        expected_outcome: :success,
        allowed: [%i[primary reader], %i[primary writer], %i[secondary reader], %i[secondary writer]]
      )
    ]
  end

  def in_home_strict_writer_txn
    Scenario.new(
      id: 'B-txn', description: 'in_home strict_writer, open transaction',
      props_args: { in_home_mode: 'strict_writer', out_of_home_mode: 'strict_writer' },
      expected_outcome: :txn_unknown, allowed: [%i[primary writer]]
    )
  end
end
