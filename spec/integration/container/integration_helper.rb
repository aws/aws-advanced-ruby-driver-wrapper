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
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'

module Integration
  module IntegrationHelper
    LOGGER = Logger.new($stdout, progname: 'Integration::IntegrationHelper')

    # Runs before each example. Call from a before(:each) hook in integration specs.
    def self.setup_test(current_driver: nil, test_name: nil)
      env = TestEnvironment.current
      env.current_driver = current_driver

      LOGGER.info("Starting test preparation for: #{test_name}")

      ProxyHelper.enable_all_connectivity if env.features.include?(TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED)

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
      ProxyHelper.enable_all_connectivity
    end

    def self.reset_caches
      AwsRubyDatabaseDriverWrapper::Utils::RdsUtils.clear_cache
    end
    private_class_method :reset_caches

    def self.wait_for_instances(rds_utility, num_instances, cluster_name)
      instances = []
      deadline = Time.now + 300
      loop do
        begin
          instances = rds_utility.instance_ids
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

# ─── RSpec hooks ─────────────────────────────────────────────────────────────

RSpec.shared_context 'integration setup' do
  before(:each) do |example|
    driver = example.metadata[:test_driver]
    Integration::IntegrationHelper.setup_test(
      current_driver: driver,
      test_name: example.full_description
    )
  end
end

RSpec.configure do |config|
  config.include_context 'integration setup', :integration
  config.include Integration::ConditionChecker, :integration

  config.before(:each, :integration) do |example|
    if (deployments = example.metadata[:deployments])
      enable_on_deployments(*deployments)
    end
    if (deployments = example.metadata[:require_deployments])
      require_deployments(*deployments)
    end
    if (features = example.metadata[:features])
      enable_on_features(*features)
    end
    if (engines = example.metadata[:enable_on_engines])
      enable_on_engines(*engines)
    end
    if (engines = example.metadata[:disable_on_engines])
      disable_on_engines(*engines)
    end
    if (features = example.metadata[:disable_on_features])
      disable_on_features(*features)
    end
  end

  # Parameterise by allowed test drivers. Tag specs with :parameterize_drivers
  # and iterate over allowed_test_drivers in shared examples.
  config.before(:each, :parameterize_drivers) do
    env = Integration::TestEnvironment.current
    skip 'No allowed drivers for this environment' if env.allowed_test_drivers.empty?
  end
end
