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

require 'resolv'
require 'aws_ruby_database_driver_wrapper/postgresql'
require 'aws_ruby_database_driver_wrapper/mysql'

require_relative 'utils/condition_checker'
require_relative 'utils/connection_utils'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/proxy_helper'
require_relative 'utils/rds_test_utility'
require_relative 'utils/spec_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'

module Integration
  module IntegrationHelper
    AwsRubyDatabaseDriverWrapper.logger.level = Logger::DEBUG
    $stderr.sync = true
    $stdout.sync = true

    LOGGER = Logger.new($stdout, progname: 'Integration::IntegrationHelper')

    # Runs before each example. Call from a before(:each) hook in integration specs.
    def self.setup_test(current_driver: nil, test_name: nil)
      env = TestEnvironment.current
      env.current_driver = current_driver

      LOGGER.info("Starting test preparation for: #{test_name}")

      if env.features.include?(TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED)
        # A previous example may have left a simulated failure pending, whose background thread re-enables
        # connectivity once its window closes. Waiting for it here keeps that re-enable from landing in the
        # middle of this example, after the outage this example sets up.
        RdsTestUtility.await_pending_failures
        ProxyHelper.enable_all_connectivity
      end

      deployment = env.deployment
      return unless [DatabaseEngineDeployment::AURORA, DatabaseEngineDeployment::RDS_MULTI_AZ_CLUSTER].include?(deployment)

      rds_utility = RdsTestUtility.new(env.aurora_region, endpoint: env.rds_endpoint)
      rds_utility.wait_until_cluster_has_desired_status(env.cluster_name, 'available')

      # Wait up to 5 minutes for cluster API topology to match SQL topology
      num_instances = env.num_of_instances
      instances = wait_for_instances(rds_utility, num_instances, env.cluster_name)

      current_writer = instances.first

      rds_utility.make_sure_instances_up(instances)

      env.database_info.move_instance_first(current_writer)
      env.proxy_database_info&.move_instance_first(current_writer)

      # Wait up to 5 minutes for the cluster endpoint DNS to resolve to the writer
      cluster_endpoint = env.database_info.cluster_endpoint
      writer_host = env.database_info.instances.first.host
      wait_for_dns(cluster_endpoint, writer_host)

      reset_caches
    end

    # Re-enables all connectivity on suite teardown.
    def self.teardown_session
      RdsTestUtility.await_pending_failures
      ProxyHelper.enable_all_connectivity
    end

    def self.reset_caches
      AwsRubyDatabaseDriverWrapper::Utils::RdsUtils.clear_cache
    end
    private_class_method :reset_caches

    def self.wait_for_instances(rds_utility, num_instances, cluster_name)
      instances = []
      deadline = Time.now + 300
      # The SQL topology is read through the instance the previous example left first, which after a failover
      # can be an instance that is still restarting. The cluster endpoint resolves to whichever instance is
      # currently the writer, so it is tried as well before giving the attempt up.
      hosts = [nil, TestEnvironment.current.database_info.cluster_endpoint].uniq
      loop do
        instances = []
        hosts.each do |host|
          instances = rds_utility.instance_ids(host: host)
          break unless instances.empty?
        rescue StandardError => e
          LOGGER.warn("ExceptionWhileObtainingInstanceIDs: #{e.message}")
          instances = []
        end
        writer_ok = instances.size >= num_instances &&
                    !instances.empty? &&
                    rds_utility.db_instance_writer?(instances.first, cluster_id: cluster_name)
        break if writer_ok
        break if Time.now >= deadline

        sleep(5)
      end
      raise 'No instances found after waiting' if instances.empty?

      instances
    end
    private_class_method :wait_for_instances

    def self.wait_for_dns(cluster_endpoint, writer_host)
      deadline = Time.now + 300
      loop do
        cluster_ip = begin
          Resolv.getaddress(cluster_endpoint)
        rescue StandardError
          nil
        end
        writer_ip = begin
          Resolv.getaddress(writer_host)
        rescue StandardError
          nil
        end
        break if cluster_ip && cluster_ip == writer_ip
        break if Time.now >= deadline

        sleep(5)
      end
      cluster_ip = begin
        Resolv.getaddress(cluster_endpoint)
      rescue StandardError
        nil
      end
      writer_ip = begin
        Resolv.getaddress(writer_host)
      rescue StandardError
        nil
      end
      return if cluster_ip == writer_ip

      raise "Cluster endpoint #{cluster_endpoint} (#{cluster_ip}) does not resolve to writer #{writer_host} (#{writer_ip})"
    end
    private_class_method :wait_for_dns
  end
end
