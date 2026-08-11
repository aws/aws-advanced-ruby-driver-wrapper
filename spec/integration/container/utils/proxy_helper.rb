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

require 'net/http'
require 'json'
require_relative 'test_environment'
require_relative 'test_utils'

module Integration
  class ProxyHelper
    class << self
      def disable_all_connectivity
        TestEnvironment.current.proxy_infos.each { |p| disable_proxy_instance(p) }
      end

      # Cuts connectivity to every proxied instance endpoint, leaving the proxied cluster endpoints up.
      # ProxyHelper.disable_all_connectivity takes the cluster endpoints down as well.
      def disable_instance_connectivity
        TestEnvironment.current.proxy_instances.each { |instance| Integration::ProxyHelper.disable_connectivity(instance.instance_id) }
      end

      def disable_connectivity(instance_name)
        disable_proxy(instance_name)
      end

      def enable_all_connectivity
        TestEnvironment.current.proxy_infos.each { |p| enable_proxy_instance(p) }
      end

      def enable_connectivity(instance_name)
        enable_proxy(instance_name)
      end

      def disable_proxy(instance_name)
        disable_proxy_instance(TestEnvironment.current.proxy_info(instance_name))
      end

      def enable_proxy(instance_name)
        enable_proxy_instance(TestEnvironment.current.proxy_info(instance_name))
      end

      private

      def disable_proxy_instance(proxy_info)
        Toxiproxy.host = "http://#{proxy_info.control_host}:#{proxy_info.control_port}"
        proxy_info.proxy.disable
        TestUtils.logger.debug("Testing.DisabledProxy: #{proxy_info.proxy.name}")
      end

      def enable_proxy_instance(proxy_info)
        Toxiproxy.host = "http://#{proxy_info.control_host}:#{proxy_info.control_port}"
        proxy_info.proxy.enable
        TestUtils.logger.debug("Testing.EnabledProxy: #{proxy_info.proxy.name}")
      end

      def disable_proxy_connectivity(proxy_info)
        Toxiproxy.host = "http://#{proxy_info.control_host}:#{proxy_info.control_port}"
        add_toxic(proxy_info, 'DOWN-STREAM', 'downstream')
        add_toxic(proxy_info, 'UP-STREAM', 'upstream')
        TestUtils.logger.debug("Testing.DisabledConnectivity: #{proxy_info.proxy.name}")
      end

      def add_toxic(proxy_info, name, stream)
        uri = URI("http://#{proxy_info.control_host}:#{proxy_info.control_port}/proxies/#{URI.encode_www_form_component(proxy_info.proxy.name)}/toxics")
        body = JSON.generate(type: 'bandwidth', name: name, stream: stream, toxicity: 1.0, attributes: { rate: 0 })
        req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
        req.body = body
        Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
      end

      def enable_proxy_connectivity(proxy_info)
        Toxiproxy.host = "http://#{proxy_info.control_host}:#{proxy_info.control_port}"
        proxy_info.proxy.toxics.each do |toxic|
          toxic.destroy if %w[DOWN-STREAM UP-STREAM].include?(toxic.name)
        end
        TestUtils.logger.debug("Testing.EnabledConnectivity: #{proxy_info.proxy.name}")
      end
    end
  end
end
