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

require_relative 'host_availability'
require_relative 'host_availability_strategy'
require_relative 'host_role'

module AwsRubyDriverWrapper
  module Host
    class HostInfo
      NO_PORT = '-1'
      NO_HOST = ''
      DEFAULT_WEIGHT = 100

      # The attributes that define this host's identity, and that {#==} and {#hash} are derived from. They are
      # read-only so that the hash code of an instance cannot change while it is held in a Hash or Set, which
      # would otherwise make the instance impossible to look up. Use {#deep_dup} to obtain a copy with
      # different values.
      attr_reader :host, :port, :role

      attr_accessor :availability_strategy, :weight, :id, :last_update_time

      def initialize(
        host: NO_HOST,
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
      end

      def ==(other)
        return true if equal?(other)
        return false unless other.is_a?(HostInfo)

        host == other.host &&
          port == other.port &&
          role == other.role
      end

      alias eql? ==

      def hash
        [host, port, role].hash
      end

      def to_s
        "HostInfo(#{host}, #{port}, #{role}, #{availability})"
      end

      def inspect
        to_s
      end

      # Returns a deep copy of this HostInfo, duplicating all mutable fields. Since {#host}, {#port} and {#role}
      # are read-only, this is also the way to obtain an instance that differs from this one in any of them.
      #
      # @param host [String] the host of the copy, defaulting to this host's.
      # @param port [String] the port of the copy, defaulting to this host's.
      # @param role [Symbol] the role of the copy, defaulting to this host's.
      # @return [HostInfo]
      def deep_dup(host: self.host, port: self.port, role: self.role)
        HostInfo.new(
          host: host.dup,
          port: port.dup,
          role:,
          availability:,
          weight:,
          id: id&.dup,
          last_update_time:
        )
      end

      def url
        "#{host_and_port}/"
      end

      def host_and_port
        port_specified? ? "#{host}:#{port}" : host
      end

      def port_specified?
        port != NO_PORT
      end

      def host_specified?
        !host.nil? && host != NO_HOST
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
