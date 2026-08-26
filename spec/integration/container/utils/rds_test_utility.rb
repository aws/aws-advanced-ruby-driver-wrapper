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

require 'aws-sdk-rds'
require_relative 'database_engine'
require_relative 'database_engine_deployment'
require_relative 'driver_helper'
require_relative 'proxy_helper'
require_relative 'test_driver'
require_relative 'test_environment'
require_relative 'test_instance_info'

module Integration
  class RdsTestUtility
    TRUE_VALUES = [true, 1, '1', 'true', 't', 'TRUE', 'T'].freeze

    # An example that triggers a real cluster failover leaves the demoted instance rebooting, and Aurora reports
    # the cluster as 'available' again long before that instance accepts connections. Recovery has been observed
    # to take around 9 minutes, so give it more room than the RDS failover window suggests.
    DEFAULT_INSTANCES_UP_TIMEOUT_SECS = 600

    # simulate_temporary_failure re-enables connectivity from a background thread once the failure window
    # closes, which can be after the example that started it has finished. Those threads are tracked here so
    # that test preparation can wait for them, rather than letting a stale re-enable land in the middle of a
    # later example.
    @pending_failures = []
    @pending_failures_mutex = Mutex.new

    def self.await_pending_failures(timeout_secs: 60)
      pending = @pending_failures_mutex.synchronize do
        @pending_failures.dup.tap { @pending_failures.clear }
      end
      pending.each { |thread| thread.join(timeout_secs) }
    end

    def self.track_pending_failure(thread)
      @pending_failures_mutex.synchronize { @pending_failures << thread }
    end

    def initialize(region, endpoint: nil)
      options = { region: region }
      options[:endpoint] = endpoint if endpoint
      @client = Aws::RDS::Client.new(**options)
    end

    def self.utility
      env = TestEnvironment.current
      new(env.aurora_region, endpoint: env.rds_endpoint)
    end

    def db_instance(instance_id)
      @client.describe_db_instances(db_instance_identifier: instance_id).db_instances.first
    rescue Aws::RDS::Errors::DBInstanceNotFound
      nil
    end

    def db_instance_exist?(instance_id)
      !db_instance(instance_id).nil?
    end

    def create_db_instance(instance_id)
      env = TestEnvironment.current
      deployment = env.deployment
      raise "create_db_instance not supported for deployment: #{deployment}" unless deployment == DatabaseEngineDeployment::AURORA

      delete_db_instance(instance_id) if db_instance_exist?(instance_id)

      @client.create_db_instance(
        db_cluster_identifier: env.cluster_name,
        db_instance_identifier: instance_id,
        db_instance_class: 'db.r5.large',
        engine: self.class.aurora_engine_name(env.engine),
        publicly_accessible: true
      )

      instance = wait_until_instance_has_desired_status(instance_id, 15, 'available')
      raise "CreateDBInstanceFailed: #{instance_id}" if instance.nil?

      TestInstanceInfo.new('instanceId' => instance.db_instance_identifier,
                           'host' => instance.endpoint&.address,
                           'port' => instance.endpoint&.port)
    end

    def delete_db_instance(instance_id)
      @client.delete_db_instance(db_instance_identifier: instance_id, skip_final_snapshot: true)
      wait_until_instance_has_desired_status(instance_id, 15, 'deleted')
    end

    def wait_until_instance_has_desired_status(instance_id, wait_time_mins, desired_status)
      stop_time = Time.now + (wait_time_mins * 60)
      loop do
        raise "Timeout waiting for instance #{instance_id} to reach status '#{desired_status}'" if Time.now > stop_time

        instance = db_instance(instance_id)
        return instance if instance&.db_instance_status == desired_status
        return nil if instance.nil? && desired_status == 'deleted'

        sleep(1)
      end
    end

    def wait_until_cluster_has_desired_status(cluster_id, desired_status)
      stop_time = Time.now + 600
      loop do
        raise "Timeout: cluster #{cluster_id} did not reach '#{desired_status}'" if Time.now > stop_time

        cluster = db_cluster(cluster_id)
        return nil if cluster.nil? && desired_status == 'deleted'
        return if cluster&.status == desired_status

        sleep(10)
      end
    end

    def db_cluster(cluster_id)
      @client.describe_db_clusters(db_cluster_identifier: cluster_id).db_clusters.first
    rescue Aws::RDS::Errors::DBClusterNotFoundFault
      nil
    end

    def db_instance_writer?(instance_id, cluster_id: nil)
      cluster_id ||= TestEnvironment.current.cluster_name
      cluster = db_cluster(cluster_id)
      raise "ClusterNotFound: #{cluster_id}" if cluster.nil?

      member = cluster.db_cluster_members.find { |m| m.db_instance_identifier == instance_id }
      raise "ClusterMemberNotFound: #{instance_id}" if member.nil?

      member.is_cluster_writer
    end

    def cluster_writer_instance_id(cluster_id = nil)
      cluster_id ||= TestEnvironment.current.cluster_name
      cluster = db_cluster(cluster_id)
      raise "ClusterNotFound: #{cluster_id}" if cluster.nil?

      writer = cluster.db_cluster_members.find(&:is_cluster_writer)
      raise "WriterInstanceNotFound: #{cluster_id}" if writer.nil?

      writer.db_instance_identifier
    end

    def query_instance_id(conn, deployment: nil, engine: nil)
      deployment ||= TestEnvironment.current.deployment
      engine ||= TestEnvironment.current.engine

      case deployment
      when DatabaseEngineDeployment::AURORA
        query_aurora_instance_id(conn, engine)
      when DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER
        query_multi_az_instance_id(conn, engine)
      else
        raise "query_instance_id not supported for deployment: #{deployment}"
      end
    end

    def self.query_host_role(conn, engine)
      sql = case engine
            when DatabaseEngine::MYSQL then 'SELECT @@innodb_read_only'
            when DatabaseEngine::PG    then 'SELECT pg_catalog.pg_is_in_recovery()'
            end
      driver  = Integration::RdsTestUtility.driver_for_engine(engine)
      dialect = AwsRubyDriverWrapper::DriverDialects::DriverDialectManager
                .get_dialect(Integration::RdsTestUtility.dialect_for_driver(driver))
      row = dialect.execute(conn, sql).first
      value = row.is_a?(Hash) ? row.values.first : row[0]
      TRUE_VALUES.include?(value) ? :reader : :writer
    end

    def self.sleep_sql(engine = nil)
      engine ||= TestEnvironment.current.engine
      case engine
      when DatabaseEngine::PG then ->(seconds) { "SELECT pg_catalog.pg_sleep(#{seconds})" }
      when DatabaseEngine::MYSQL then ->(seconds) { "SELECT SLEEP(#{seconds})" }
      else raise "InvalidDatabaseEngine: #{engine}"
      end
    end

    def self.instance_id_query(engine = nil)
      engine ||= TestEnvironment.current.engine
      case engine
      when DatabaseEngine::MYSQL then 'SELECT @@aurora_server_id'
      when DatabaseEngine::PG then 'SELECT pg_catalog.aurora_db_instance_identifier()'
      else raise "Unsupported engine: #{engine}"
      end
    end

    def instance_ids(host: nil)
      env = TestEnvironment.current
      case env.deployment
      when DatabaseEngineDeployment::AURORA
        aurora_instance_ids(host)
      when DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER
        multi_az_instance_ids(host)
      else
        raise "instance_ids not supported for deployment: #{env.deployment}"
      end
    end

    # Waits for every known instance in instance_ids to accept a connection. timeout_secs bounds the call as a
    # whole rather than each instance, so the worst case does not grow with the number of instances in the cluster.
    def make_sure_instances_up(instance_ids, timeout_secs: DEFAULT_INSTANCES_UP_TIMEOUT_SECS)
      db_info = TestEnvironment.current.database_info
      suffix = db_info.instance_endpoint_suffix
      port = db_info.instance_endpoint_port
      known_hosts = db_info.instances.to_set(&:host)
      deadline = Time.now + timeout_secs
      instance_ids.each do |id|
        host = "#{id}.#{suffix}"
        next unless known_hosts.include?(host)

        instance_info = TestInstanceInfo.new('instanceId' => id, 'host' => host, 'port' => port)
        loop do
          open_connection(instance_info).tap(&:close)
          break
        rescue StandardError
          raise "Instance #{id} did not come up within #{timeout_secs} seconds" if Time.now >= deadline

          sleep(1)
        end
      end
    end

    def self.create_user(conn, username, password)
      raise ArgumentError, "Invalid username: #{username}" unless username.match?(/\A\w+\z/)

      engine = TestEnvironment.current.engine
      escaped_password = case engine
                         when DatabaseEngine::PG    then conn.escape_string(password)
                         when DatabaseEngine::MYSQL then conn.escape(password)
                         else raise "InvalidDatabaseEngine: #{engine}"
                         end
      sql = case engine
            when DatabaseEngine::PG    then "CREATE USER #{username} WITH PASSWORD '#{escaped_password}'"
            when DatabaseEngine::MYSQL then "CREATE USER #{username} IDENTIFIED BY '#{escaped_password}'"
            end
      driver  = Integration::RdsTestUtility.driver_for_engine(engine)
      dialect = AwsRubyDriverWrapper::DriverDialects::DriverDialectManager
                .get_dialect(Integration::RdsTestUtility.dialect_for_driver(driver))
      dialect.execute(conn, sql)
    end

    def assert_first_query_throws(conn, exception_cls, deployment: nil, engine: nil)
      deployment ||= TestEnvironment.current.deployment
      engine     ||= TestEnvironment.current.engine
      query_instance_id(conn, deployment: deployment, engine: engine)
      raise "Expected #{exception_cls} to be raised but nothing was raised"
    rescue exception_cls
      # expected — test passes
    end

    def db_cluster_by_arn(cluster_arn)
      @client.describe_db_clusters(filters: [{ name: 'db-cluster-id', values: [cluster_arn] }]).db_clusters.first
    rescue Aws::RDS::Errors::DBClusterNotFoundFault
      nil
    end

    def db_instance_by_arn(instance_arn)
      @client.describe_db_instances(filters: [{ name: 'db-instance-id', values: [instance_arn] }]).db_instances.first
    rescue Aws::RDS::Errors::DBInstanceNotFound
      nil
    end

    # Triggers a Blue/Green Deployment switchover via the RDS API.
    def switchover_blue_green_deployment(bgd_id)
      @client.switchover_blue_green_deployment(
        blue_green_deployment_identifier: bgd_id
      )
    end

    # Retrieves a Blue/Green Deployment descriptor.
    # Returns nil if not found.
    def get_blue_green_deployment(bgd_id)
      resp = @client.describe_blue_green_deployments(
        blue_green_deployment_identifier: bgd_id
      )
      resp.blue_green_deployments.first
    rescue Aws::RDS::Errors::BlueGreenDeploymentNotFoundFault
      nil
    end

    # Resolves all blue and green instance endpoints for a Blue/Green Deployment.
    # Returns an array of endpoint hostnames (strings).
    #
    # For Aurora: queries both blue and green clusters for all instance endpoints.
    # For RDS Multi-AZ Instance: returns the blue and green instance endpoints directly.
    def get_blue_green_endpoints(bgd_id, deployment:, engine:)
      bg_deployment = get_blue_green_deployment(bgd_id)
      raise "Blue/Green Deployment not found: #{bgd_id}" if bg_deployment.nil?

      case deployment
      when DatabaseEngineDeployment::RDS_MULTI_AZ_INSTANCE
        get_rds_instance_bg_endpoints(bg_deployment)
      when DatabaseEngineDeployment::AURORA
        get_aurora_bg_endpoints(bg_deployment, engine)
      else
        raise "Unsupported deployment for BG endpoints: #{deployment}"
      end
    end

    def simulate_temporary_failure(instance_name, delay_secs, failure_duration_secs)
      sleep(delay_secs) if delay_secs.positive?

      # Disable connectivity synchronously in the caller's thread so that any failure is raised
      # here instead of being silently swallowed in a background thread.
      disable_instance_connectivity(instance_name)

      # Re-enable in the background after the failure window so the test can observe failover while
      # the instance is unreachable. A failure to re-enable is logged rather than swallowed.
      thread = Thread.new do
        sleep(failure_duration_secs)
      ensure
        begin
          enable_instance_connectivity(instance_name)
        rescue StandardError => e
          TestUtils.logger.error("Failed to re-enable connectivity for #{instance_name}: #{e.message}")
        end
      end
      self.class.track_pending_failure(thread)
      thread
    end

    def disable_instance_connectivity(instance_name)
      if instance_name == '*'
        ProxyHelper.disable_all_connectivity
      else
        ProxyHelper.disable_proxy(instance_name)
      end
    end

    def enable_instance_connectivity(instance_name)
      if instance_name == '*'
        ProxyHelper.enable_all_connectivity
      else
        ProxyHelper.enable_proxy(instance_name)
      end
    end

    def self.aurora_engine_name(engine)
      case engine
      when DatabaseEngine::PG then 'aurora-postgresql'
      when DatabaseEngine::MYSQL then 'aurora-mysql'
      else raise "InvalidDatabaseEngine: #{engine}"
      end
    end

    def self.driver_for_engine(engine)
      case engine
      when DatabaseEngine::MYSQL then Integration::TestDriver::MYSQL
      when DatabaseEngine::PG then Integration::TestDriver::PG
      else raise "Unsupported engine: #{engine}"
      end
    end

    def self.dialect_for_driver(driver)
      case driver
      when Integration::TestDriver::MYSQL then :mysql2
      when Integration::TestDriver::PG then :postgresql
      else raise "Unknown driver: #{driver}"
      end
    end

    def crash_instance(instance_id)
      env = TestEnvironment.current
      if env.deployment == DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER
        simulate_temporary_failure(instance_id, 0, 5)
        sleep(1)
      else
        failover_cluster_and_wait_until_writer_changed
      end
    end

    def failover_cluster_and_wait_until_writer_changed(max_retries: 3)
      env = TestEnvironment.current
      cluster_id = env.cluster_name
      initial_writer_id = cluster_writer_instance_id(cluster_id)

      writer_changed = false
      max_retries.times do |attempt|
        @client.failover_db_cluster(db_cluster_identifier: cluster_id)

        writer_changed = RetryHelper.retry_until(timeout_secs: 300, delay_secs: 5) do
          current_writer = cluster_writer_instance_id(cluster_id)
          current_writer != initial_writer_id
        end
        break if writer_changed

        TestUtils.logger.warn("Failover attempt #{attempt + 1}/#{max_retries}: writer did not change, retrying")
      end

      raise "Writer did not change after #{max_retries} failover attempts" unless writer_changed
    end

    def sleep_sql(seconds)
      self.class.sleep_sql(TestEnvironment.current.engine).call(seconds)
    end

    private

    def get_rds_instance_bg_endpoints(bg_deployment)
      blue_instance = db_instance_by_arn(bg_deployment.source)
      raise 'Blue instance not found from BG deployment source ARN' if blue_instance.nil?

      green_instance = db_instance_by_arn(bg_deployment.target)
      raise 'Green instance not found from BG deployment target ARN' if green_instance.nil?

      [blue_instance.endpoint.address, green_instance.endpoint.address]
    end

    def get_aurora_bg_endpoints(bg_deployment, _engine)
      # Blue cluster instances
      blue_cluster = db_cluster_by_arn(bg_deployment.source)
      raise 'Blue cluster not found from BG deployment source ARN' if blue_cluster.nil?

      env = TestEnvironment.current
      endpoints = env.database_info.instances.map(&:host)

      # Green cluster instances
      green_cluster = db_cluster_by_arn(bg_deployment.target)
      raise 'Green cluster not found from BG deployment target ARN' if green_cluster.nil?

      green_instance_ids = aurora_instance_ids(green_cluster.endpoint)
      raise "Can't find green cluster instances for #{green_cluster.endpoint}" if green_instance_ids.empty?

      instance_pattern = AwsRubyDriverWrapper::Utils::RdsUtils.rds_instance_host_pattern(green_cluster.endpoint)
      green_instance_ids.each do |instance_id|
        endpoints << instance_pattern.sub('?', instance_id)
      end

      endpoints
    end

    def query_aurora_instance_id(conn, engine)
      sql = self.class.instance_id_query(engine)
      row = execute(conn, sql, self.class.driver_for_engine(engine)).first
      row.is_a?(Hash) ? row.values.first : row
    end

    def query_multi_az_instance_id(conn, engine)
      endpoint_sql = case engine
                     when DatabaseEngine::MYSQL
                       'SELECT endpoint FROM mysql.rds_topology WHERE id=(SELECT @@server_id)'
                     when DatabaseEngine::PG
                       'SELECT endpoint FROM rds_tools.show_topology() WHERE id=(SELECT dbi_resource_id FROM rds_tools.dbi_resource_id())'
                     else raise "Unsupported engine: #{engine}"
                     end
      driver = self.class.driver_for_engine(engine)
      row = execute(conn, endpoint_sql, driver).first
      endpoint = row.is_a?(Hash) ? row.values.first : row
      endpoint.split('.').first
    end

    def execute(conn, sql, driver)
      AwsRubyDriverWrapper::DriverDialects::DriverDialectManager
        .get_dialect(self.class.dialect_for_driver(driver))
        .execute(conn, sql)
    end

    def open_connection(instance_info, host: nil)
      env = TestEnvironment.current
      driver = self.class.driver_for_engine(env.engine)
      params = Integration::DriverHelper.native_config(
        driver,
        host: host || instance_info.host,
        port: instance_info.port,
        user: env.database_info.username,
        password: env.database_info.password,
        dbname: env.database_info.default_dbname
      )
      Integration::DriverHelper.native_connect(driver, **params, connect_timeout: 10)
    end

    def aurora_instance_ids(host)
      env = TestEnvironment.current
      sql = aurora_topology_sql(env.engine)
      driver = self.class.driver_for_engine(env.engine)
      conn = open_connection(env.writer, host: host)
      execute(conn, sql, driver).map do |row|
        row.is_a?(Hash) ? (row['SERVER_ID'] || row[:server_id] || row.values.first) : row[0]
      end
    ensure
      conn&.close
    end

    def multi_az_instance_ids(host)
      env = TestEnvironment.current
      cluster_instance = TestInstanceInfo.new(
        'host' => env.database_info.cluster_endpoint,
        'port' => env.database_info.cluster_endpoint_port
      )
      conn = open_connection(cluster_instance, host: host)

      driver = self.class.driver_for_engine(env.engine)
      execute(conn, multi_az_topology_sql(env.engine, multi_az_writer_id(conn, driver, env.engine)), driver).map do |row|
        endpoint = row.is_a?(Hash) ? (row['endpoint'] || row[:endpoint] || row.values[1]) : row[1]
        endpoint.split('.').first
      end
    ensure
      conn&.close
    end

    def multi_az_writer_id(conn, driver, engine)
      case engine
      when DatabaseEngine::MYSQL
        execute(conn, 'SHOW REPLICA STATUS', driver).first ||
          execute(conn, 'SELECT @@server_id', driver).first
      when DatabaseEngine::PG
        sql = 'SELECT multi_az_db_cluster_source_dbi_resource_id FROM ' \
              'rds_tools.multi_az_db_cluster_source_dbi_resource_id()'
        execute(conn, sql, driver).first ||
          execute(conn, 'SELECT dbi_resource_id FROM rds_tools.dbi_resource_id()', driver).first
      else raise "Unsupported engine: #{engine}"
      end
    end

    def aurora_topology_sql(engine)
      case engine
      when DatabaseEngine::MYSQL
        "SELECT SERVER_ID, SESSION_ID FROM information_schema.replica_host_status ORDER BY IF(SESSION_ID = 'MASTER_SESSION_ID', 0, 1)"
      when DatabaseEngine::PG
        'SELECT SERVER_ID, SESSION_ID FROM pg_catalog.aurora_replica_status() ' \
        "ORDER BY CASE WHEN SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID' THEN 0 ELSE 1 END"
      else raise "Unsupported engine: #{engine}"
      end
    end

    def multi_az_topology_sql(engine, writer_id)
      case engine
      when DatabaseEngine::MYSQL
        "SELECT id, endpoint, port FROM mysql.rds_topology ORDER BY id = '#{writer_id}' DESC"
      when DatabaseEngine::PG
        "SELECT id, endpoint, port FROM rds_tools.show_topology() ORDER BY id OPERATOR(pg_catalog.=) '#{writer_id}' DESC"
      else raise "Unsupported engine: #{engine}"
      end
    end
  end
end
