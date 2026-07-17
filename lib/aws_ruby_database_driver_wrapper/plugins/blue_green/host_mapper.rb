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
require_relative '../../host/host_info'
require_relative '../../host/host_role'
require_relative '../../utils/rds_utils'
require_relative 'role'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      class HostMapper
        attr_reader :corresponding_hosts, :role_by_host, :host_ip_addresses

        def initialize
          @corresponding_hosts = Concurrent::Hash.new
          @role_by_host        = Concurrent::Hash.new
          @host_ip_addresses   = Concurrent::Hash.new
        end

        def update(source_status, target_status)
          @corresponding_hosts.clear

          build_instance_pairs(source_status, target_status)
          build_cluster_pairs(source_status, target_status)
        end

        def merge_ips(ip_map)
          @host_ip_addresses.merge!(ip_map)
        end

        def register_role(host_names, role)
          host_names.each { |x| @role_by_host[x.downcase] = role }
        end

        def clear
          @corresponding_hosts.clear
          @role_by_host.clear
          @host_ip_addresses.clear
        end

        def to_debug_s
          @corresponding_hosts.map { |k, v| "   #{k} -> #{v[1]&.host_and_port || '<null>'}" }.join("\n")
        end

        private

        def build_instance_pairs(source_status, target_status)
          return unless source_status&.start_topology&.any? && target_status&.start_topology&.any?

          blue_writer  = writer_host(source_status)
          green_writer = writer_host(target_status)
          blue_readers  = reader_hosts(source_status)
          green_readers = reader_hosts(target_status)

          @corresponding_hosts[blue_writer.host] = [blue_writer, green_writer] if blue_writer

          return unless blue_readers&.any?

          if green_readers&.any?
            blue_readers.each_with_index do |blue, i|
              @corresponding_hosts[blue.host] = [blue, green_readers[i % green_readers.size]]
            end
          else
            blue_readers.each { |blue| @corresponding_hosts[blue.host] = [blue, green_writer] }
          end
        end

        def build_cluster_pairs(source_status, target_status)
          return unless source_status&.host_names&.any? && target_status&.host_names&.any?

          blue_hosts  = source_status.host_names
          green_hosts = target_status.host_names

          pair_by_dns_type(blue_hosts, green_hosts, :writer_cluster_dns?)
          pair_by_dns_type(blue_hosts, green_hosts, :reader_cluster_dns?)
          pair_custom_clusters(blue_hosts, green_hosts)
        end

        def pair_by_dns_type(blue_hosts, green_hosts, dns_method)
          blue  = blue_hosts.find  { |h| Utils::RdsUtils.public_send(dns_method, h) }
          green = green_hosts.find { |h| Utils::RdsUtils.public_send(dns_method, h) }
          return unless blue && green

          @corresponding_hosts[blue] ||= [Host::HostInfo.new(host: blue), Host::HostInfo.new(host: green)]
        end

        def pair_custom_clusters(blue_hosts, green_hosts)
          blue_hosts.select { |h| Utils::RdsUtils.rds_custom_cluster_dns?(h) }.each do |blue_host|
            custom_name = Utils::RdsUtils.rds_cluster_id(blue_host)
            next unless custom_name

            green_host = green_hosts.find do |x|
              Utils::RdsUtils.rds_custom_cluster_dns?(x) &&
                custom_name == Utils::RdsUtils.remove_green_instance_prefix(Utils::RdsUtils.rds_cluster_id(x))
            end
            next unless green_host

            @corresponding_hosts[blue_host] ||= [
              Host::HostInfo.new(host: blue_host),
              Host::HostInfo.new(host: green_host)
            ]
          end
        end

        def writer_host(interim_status)
          interim_status.start_topology&.find { |x| x.role == Host::HostRole::WRITER }
        end

        def reader_hosts(interim_status)
          interim_status.start_topology
                        &.reject { |x| x.role == Host::HostRole::WRITER }
                        &.sort_by(&:host)
        end
      end
    end
  end
end
