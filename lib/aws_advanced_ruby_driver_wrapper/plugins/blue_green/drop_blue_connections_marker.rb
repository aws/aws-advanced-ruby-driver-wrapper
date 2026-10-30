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

require 'securerandom'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module BlueGreen
      # Records that a Blue/Green switchover is retiring the blue environment, so that connections
      # opened to blue before the switchover can be invalidated the next time they are used.
      #
      # Ruby cannot safely abort a connection from another thread, so instead of dropping blue connections
      # from the monitor thread, each connection checks this marker on its own thread the next time it is
      # used. See the +bg_drop_blue_connections+ property and BlueGreenPlugin#execute.
      #
      # A marker is immutable. It becomes +pending+ when the switchover reaches IN_PROGRESS and is
      # replaced by an +active+ copy (see #activated) once the switchover is confirmed by POST or
      # COMPLETED. It is cleared on rollback.
      class DropBlueConnectionsMarker
        # @return [String] a unique identity for this switchover's marker, so a connection can tell
        #   whether it has already been checked against it.
        attr_reader :id

        # @return [Integer] monotonic time (nanoseconds) at which the switchover reached IN_PROGRESS.
        attr_reader :switchover_time_ns

        # @return [Set<String>] the blue host set: downcased cluster and instance endpoint names plus
        #   their pre-switchover IP addresses.
        attr_reader :blue_hosts

        # @param blue_hosts [Enumerable<String>] blue endpoint names and their pre-switchover IPs
        # @param switchover_time_ns [Integer] monotonic time the switchover reached IN_PROGRESS
        # @param id [String] unique identity for this marker
        # @param active [Boolean] false while the switchover is in progress, true once it is confirmed
        def initialize(blue_hosts:, switchover_time_ns:, id: SecureRandom.uuid, active: false)
          @id = id
          @switchover_time_ns = switchover_time_ns
          @blue_hosts = blue_hosts.to_set.freeze
          @active = active
          freeze
        end

        def active?
          @active
        end

        # @return [DropBlueConnectionsMarker] an active copy of this marker, keeping its identity.
        def activated
          return self if @active

          DropBlueConnectionsMarker.new(
            blue_hosts: @blue_hosts, switchover_time_ns: @switchover_time_ns, id: @id, active: true
          )
        end

        # Whether a connection opened to the given host at the given time is now a stale blue connection.
        #
        # @param host [String, nil] the downcased connect-time host of the connection
        # @param open_time_ns [Integer, nil] the monotonic time the connection was opened
        # @return [Boolean]
        def stale?(host, open_time_ns)
          return false unless @active
          return false if host.nil? || open_time_ns.nil?
          return false unless open_time_ns < @switchover_time_ns

          @blue_hosts.include?(host)
        end
      end
    end
  end
end
