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

require 'set'
require_relative 'host_availability'
require_relative 'host_availability_strategy'
require_relative 'host_role'

module AwsAdvancedRubyWrapper
  module Host
    class HostInfo
      NO_PORT = -1
      DEFAULT_WEIGHT = 100

      attr_accessor :host, :port, :role, :availability_strategy, :weight, :id, :last_update_time

      def initialize(
        host:,
        port: NO_PORT,
        role: HostRole::WRITER,
        availability: HostAvailability::AVAILABLE,
        availability_strategy: HostAvailabilityStrategy.new,
        weight: DEFAULT_WEIGHT,
        id: nil,
        last_update_time: nil
      )
        @host = host
        @port = port
        @role = role
        @availability = availability
        @availability_strategy = availability_strategy
        @weight = weight
        @id = id
        @last_update_time = last_update_time
        @all_identifiers = Set.new([host_and_port])
      end

      def ==(other)
        return true if equal?(other)
        return false unless other.is_a?(HostInfo)

        host == other.host &&
          port == other.port &&
          role == other.role
      end

      def to_s
        "HostInfo(#{host}, #{port}, #{role}, #{availability})"
      end

      def inspect
        to_s
      end

      def dup
        HostInfo.new(
          host: host,
          port: port,
          role: role,
          availability: availability,
          weight: weight,
          id: id,
          last_update_time: last_update_time
        )
      end

      def url
        "#{host_and_port}/"
      end

      # Returns all identifiers for this host, which consists of the value returned by {#host_and_port} plus various
      # aliases, such as the internal IP address, instance URL, or instance name. An example return set could look like
      # {
      #   foo.cluster-xyz.rds.amazonaws.com:3306,
      #   ip-1-2-3-4:3306,
      #   foo-instance-1.xyz.rds.amazonaws.com,
      #   foo-instance-1
      # }
      #
      # @return [Set] the set of all identifiers for this host.
      def all_identifiers
        @all_identifiers.dup.freeze
      end

      def host_and_port
        port_specified? ? "#{host}:#{port}" : host
      end

      # Adds aliases for this host to the set of {#all_identifiers}.
      #
      # @param aliases [Array<String>] the aliases to add (e.g. IP address, instance name)
      # @return [void]
      def add_aliases(*aliases)
        return if aliases.empty?

        aliases.each do |a|
          @all_identifiers.add(a)
        end
      end

      # Removes aliases for this host from the set of {#all_identifiers}.
      #
      # @param aliases [Array<String>] the aliases to remove (e.g. IP address, instance name)
      # @return [void]
      def remove_aliases(*aliases)
        return if aliases.empty?

        aliases.each do |a|
          @all_identifiers.delete(a)
        end
      end

      # Resets {#all_identifiers} by removing all aliases so that it only contains the {#host_and_port}.
      #
      # @return [void]
      def reset_identifiers
        @all_identifiers.clear
        @all_identifiers.add(host_and_port)
      end

      def port_specified?
        port != NO_PORT
      end

      # Returns the availability of this host.
      #
      # @return [Symbol] either {HostAvailability::AVAILABLE} or {HostAvailability::UNAVAILABLE}
      def availability
        return availability_strategy.host_availability(@availability) if availability_strategy

        @availability
      end

      def availability=(availability)
        @availability = availability
        availability_strategy&.host_availability = availability
      end

      # Returns the raw availability of this host.
      #
      # @return [Symbol] the raw availability of this host, ignoring the
      #   {#availability_strategy} if it has one.
      def raw_availability
        @availability
      end
    end
  end
end
