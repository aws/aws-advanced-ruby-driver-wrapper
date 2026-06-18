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

require 'json'
require_relative 'database_engine'
require_relative 'database_engine_deployment'
require_relative 'proxy_info'
require_relative 'test_driver'
require_relative 'test_environment_features'
require_relative 'test_environment_info'
require_relative 'test_environment_request'

module Integration
  class TestEnvironment
    def initialize(test_info)
      @info = TestEnvironmentInfo.new(test_info)
      @proxies = nil
      @current_driver = nil
    end

    attr_accessor :current_driver

    def to_s
      "TestEnvironment[deployment=#{deployment},engine=#{engine}," \
        "instances=#{@info.request.num_of_instances},driver=#{@current_driver}]"
    end

    def self.current
      @current ||= create
    end

    def num_of_instances
      @info.request.num_of_instances
    end

    def features
      @info.request.features
    end

    def deployment
      @info.request.deployment
    end

    def engine
      @info.request.engine
    end

    def database_info
      @info.database_info
    end

    def instances
      database_info.instances
    end

    def writer
      instances.first
    end

    def cluster_name
      @info.dbname
    end

    def proxy_database_info
      @info.proxy_database_info
    end

    def proxy_instances
      proxy_database_info.instances
    end

    def proxy_writer
      proxy_instances.first
    end

    def aurora_region
      @info.region
    end

    def iam_user_name
      @info.iam_user_name
    end

    def rds_endpoint
      @info.rds_endpoint
    end

    def proxy_info(instance_name)
      raise "Proxy not found: #{instance_name}" if @proxies.nil?

      @proxies.fetch(instance_name) { raise "Proxy not found: #{instance_name}" }
    end

    def proxy_infos
      @proxies&.values || []
    end

    def allowed_test_drivers
      TestDriver.constants.map { |c| TestDriver.const_get(c) }.select { |d| test_driver_allowed?(d) }
    end

    def test_driver_allowed?(test_driver)
      case test_driver
      when TestDriver::MYSQL
        compatible = engine == DatabaseEngine::MYSQL
        disabled = features.include?(TestEnvironmentFeatures::SKIP_MYSQL_DRIVER_TESTS)
      when TestDriver::PG
        compatible = engine == DatabaseEngine::PG
        disabled = features.include?(TestEnvironmentFeatures::SKIP_PG_DRIVER_TESTS)
      else
        raise NotImplementedError, test_driver.to_s
      end

      !disabled && compatible
    end

    private_class_method def self.create
      info_json = ENV.fetch('TEST_ENV_INFO_JSON', nil) or
        raise 'Environment variable TEST_ENV_INFO_JSON is required'

      test_info = JSON.parse(info_json)
      raise 'Could not parse TEST_ENV_INFO_JSON' if test_info.empty?

      env = new(test_info)
      init_proxies(env) if env.features.include?(TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED)

      env
    end

    private_class_method def self.init_proxies(environment)
      require 'toxiproxy'

      environment.instance_variable_set(:@proxies, {})
      proxies = environment.instance_variable_get(:@proxies)
      control_port = environment.proxy_database_info.control_port

      environment.proxy_instances.each do |instance|
        Toxiproxy.host = "http://#{instance.host}:#{control_port}"
        proxy = nil
        Toxiproxy.all.each { |p| proxy ||= p }
        raise "Proxy not found for #{instance.instance_id}" unless proxy

        proxies[instance.instance_id] = ProxyInfo.new(
          proxy, instance.host, control_port
        )
      end

      if environment.proxy_database_info.cluster_endpoint
        Toxiproxy.host = "http://#{environment.proxy_database_info.cluster_endpoint}:#{control_port}"
        proxy = Toxiproxy.find_by_name("#{environment.database_info.cluster_endpoint}:#{environment.database_info.cluster_endpoint_port}")
        if proxy
          proxies[environment.proxy_database_info.cluster_endpoint] =
            ProxyInfo.new(proxy, environment.proxy_database_info.cluster_endpoint, control_port)
        end
      end

      return unless environment.proxy_database_info.cluster_read_only_endpoint

      Toxiproxy.host = "http://#{environment.proxy_database_info.cluster_read_only_endpoint}:#{control_port}"
      proxy_name = "#{environment.database_info.cluster_read_only_endpoint}:" \
                   "#{environment.database_info.cluster_read_only_endpoint_port}"
      proxy = Toxiproxy.find_by_name(proxy_name)
      return unless proxy

      proxies[environment.proxy_database_info.cluster_read_only_endpoint] =
        ProxyInfo.new(proxy, environment.proxy_database_info.cluster_read_only_endpoint, control_port)
    end
  end
end
