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
require_relative '../../errors'
require_relative '../../logging'
require_relative '../../property_definition'
require_relative '../../utils/rds_utils'
require_relative 'custom_endpoint_monitor'

module AwsRubyDriverWrapper
  module Plugins
    module CustomEndpoint
      class CustomEndpointPlugin
        include Logging

        MONITOR_TYPE = :custom_endpoint

        attr_reader :subscribed_methods

        def initialize(service_container, props = ::Concurrent::Map.new)
          ensure_aws_sdk!
          @service_container = service_container
          @props = props
          @should_wait_for_info = PropertyDefinition::WAIT_FOR_CUSTOM_ENDPOINT_INFO.get_bool(props)
          @wait_timeout_sec = PropertyDefinition::WAIT_FOR_CUSTOM_ENDPOINT_INFO_TIMEOUT_MS.get_int(props) / 1000.0

          @custom_endpoint_host = nil
          @endpoint_id = nil
          @region = nil

          monitor_expiration_sec = PropertyDefinition::CUSTOM_ENDPOINT_MONITOR_EXPIRATION_MS.get_int(props) / 1000.0
          service_container.monitor_service.register_type(
            MONITOR_TYPE,
            expiration_timeout_sec: monitor_expiration_sec,
            produced_data_type: CustomEndpointMonitor::ENDPOINT_INFO_CACHE_NAME
          )
          service_container.storage_service.register(
            CustomEndpointMonitor::ENDPOINT_INFO_CACHE_NAME,
            ttl: CustomEndpointMonitor::ENDPOINT_INFO_EXPIRATION_SEC
          )
          service_container.storage_service.register(
            CustomEndpointMonitor::ALLOWED_BLOCKED_CACHE_NAME,
            ttl: CustomEndpointMonitor::ENDPOINT_INFO_EXPIRATION_SEC
          )

          network_methods = service_container.dialect_service.driver_dialect.network_bound_methods
          @subscribed_methods = (Set['connect'] | network_methods).freeze
        end

        def connect(host_info, _, _, pipeline_callable)
          return pipeline_callable.call unless Utils::RdsUtils.rds_custom_cluster_dns?(host_info.host)

          logger.debug("CustomEndpointPlugin: connection request to custom endpoint '#{host_info.url}'")
          init_endpoint_state!(host_info) if @custom_endpoint_host.nil?
          monitor = create_monitor_if_absent(@props)
          wait_for_endpoint_info(monitor) if @should_wait_for_info
          pipeline_callable.call
        end

        def execute(_, pipeline_callable, *_, **_)
          return pipeline_callable.call if @custom_endpoint_host.nil?

          monitor = create_monitor_if_absent(@props)
          wait_for_endpoint_info(monitor) if @should_wait_for_info
          pipeline_callable.call
        end

        def self.clear_cache(storage_service)
          CustomEndpointMonitor.clear_cache(storage_service)
        end

        private

        def init_endpoint_state!(host_info)
          @custom_endpoint_host = host_info

          endpoint_id = Utils::RdsUtils.rds_cluster_id(host_info.host)
          if endpoint_id.nil? || endpoint_id.empty?
            raise Errors::AwsError, "CustomEndpointPlugin: unable to parse endpoint identifier from '#{host_info.host}'"
          end

          @endpoint_id = endpoint_id
          @region = resolve_region!(host_info.host)
        end

        def resolve_region!(host)
          region = PropertyDefinition::CUSTOM_ENDPOINT_REGION.get(@props) || Utils::RdsUtils.rds_region(host)
          unless region
            raise Errors::AwsError,
                  "CustomEndpointPlugin: unable to determine region for '#{host}'. " \
                  "Set the '#{PropertyDefinition::CUSTOM_ENDPOINT_REGION.name}' property explicitly."
          end

          region
        end

        def create_monitor_if_absent(props)
          @service_container.monitor_service.run_if_absent(
            MONITOR_TYPE,
            @custom_endpoint_host.url,
            @service_container
          ) do |service_container|
            CustomEndpointMonitor.new(
              service_container,
              @custom_endpoint_host,
              @endpoint_id,
              @region,
              PropertyDefinition::CUSTOM_ENDPOINT_INFO_REFRESH_RATE_MS.get_int(props),
              PropertyDefinition::CUSTOM_ENDPOINT_INFO_REFRESH_RATE_BACKOFF_FACTOR.get_int(props),
              PropertyDefinition::CUSTOM_ENDPOINT_INFO_MAX_REFRESH_RATE_MS.get_int(props)
            )
          end
        end

        def wait_for_endpoint_info(monitor)
          return if monitor.endpoint_info?

          monitor.request_endpoint_info_update
          logger.debug("CustomEndpointPlugin: waiting up to #{@wait_timeout_sec}s for endpoint info on #{@custom_endpoint_host.url}")

          return if monitor.wait_for_info?(@wait_timeout_sec)

          raise Errors::AwsError,
                "CustomEndpointPlugin: timed out after #{@wait_timeout_sec}s " \
                "waiting for custom endpoint info for '#{@custom_endpoint_host.url}'"
        end

        def ensure_aws_sdk!
          require 'aws-sdk-rds'
        rescue LoadError
          raise LoadError,
                "The custom endpoint plugin requires 'aws-sdk-rds'. Add it to your Gemfile: gem 'aws-sdk-rds'"
        end
      end
    end
  end
end
