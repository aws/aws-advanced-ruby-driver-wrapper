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

require_relative '../../host/host_info'
require_relative '../../utils/rds_utils'
require_relative 'phase'
require_relative 'role'
require_relative 'routing/base_routing'
require_relative 'routing/substitute_connect_routing'
require_relative 'routing/reject_connect_routing'
require_relative 'routing/suspend_connect_routing'
require_relative 'routing/suspend_execute_routing'
require_relative 'routing/suspend_until_corresponding_host_found_connect_routing'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      # Constructs the appropriate Status object for each Blue/Green phase.
      # Each method encodes the routing rules that apply during that phase:
      #   created     — no routing; normal connect/execute behaviour.
      #   preparation — blue connects routed to their IP addresses to avoid stale DNS.
      #   in_progress — all blue/green connects and executes suspended.
      #   post        — blue connects redirected to corresponding green hosts; green connects rerouted to IPs.
      #   completed   — no routing; normal behaviour resumes.
      # If the switchover timer has expired, falls back to created (rollback) or completed.
      class StatusBuilder
        def initialize(bgd_id, host_mapper, timer, interim_statuses, iam_tracker, switchover_state)
          @bgd_id           = bgd_id
          @host_mapper      = host_mapper
          @timer            = timer
          @interim_statuses = interim_statuses
          @iam_tracker      = iam_tracker
          @switchover_state = switchover_state
        end

        def created
          Status.new(@bgd_id, Phase::CREATED,
                     connect_routing: [],
                     execute_routing: [],
                     role_by_host: @host_mapper.role_by_host,
                     corresponding_hosts: @host_mapper.corresponding_hosts)
        end

        # BGD reports COMPLETED. If DNS hasn't fully propagated yet, delegates to post.
        # Clears corresponding_hosts once DNS is confirmed settled.
        def completed(rollback)
          if @timer.expired?
            return created if rollback

            return Status.new(@bgd_id, Phase::COMPLETED,
                              connect_routing: [],
                              execute_routing: [],
                              role_by_host: @host_mapper.role_by_host,
                              corresponding_hosts: @host_mapper.corresponding_hosts)
          end

          return post(rollback) unless @switchover_state.blue_dns_update_completed && @switchover_state.green_dns_removed

          Status.new(@bgd_id, Phase::COMPLETED,
                     connect_routing: [],
                     execute_routing: [],
                     role_by_host: @host_mapper.role_by_host,
                     corresponding_hosts: {})
        end

        # POST phase: blue connects are redirected to green hosts (or suspended until a green host is found).
        # Green connects are rerouted to IPs (topology not yet updated) or rejected (DNS removed).
        def post(rollback)
          return (rollback ? created : completed(rollback)) if @timer.expired?

          Status.new(@bgd_id, Phase::POST,
                     connect_routing: post_connect_routing,
                     execute_routing: [],
                     role_by_host: @host_mapper.role_by_host,
                     corresponding_hosts: @host_mapper.corresponding_hosts)
        end

        # IN_PROGRESS: all blue/green connects and executes are suspended.
        # IP-addressed connections to known blue/green IPs are also suspended.
        def in_progress(rollback)
          return (rollback ? created : completed(rollback)) if @timer.expired?

          connect_routing = [
            Routing::SuspendConnectRouting.new(nil, nil, Role::SOURCE, @bgd_id),
            Routing::SuspendConnectRouting.new(nil, nil, Role::TARGET, @bgd_id)
          ]
          execute_routing = [
            Routing::SuspendExecuteRouting.new(nil, nil, Role::SOURCE, @bgd_id),
            Routing::SuspendExecuteRouting.new(nil, nil, Role::TARGET, @bgd_id)
          ]

          ip_connect, ip_execute = @host_mapper.host_ip_addresses.values.compact.uniq
                                               .each_with_object([[], []]) do |ip, (ic, ie)|
                                                 matched = [Role::SOURCE, Role::TARGET].find do |r|
                                                   interim = @interim_statuses[r]
                                                   interim && interim.start_ip_addresses_by_host.values.compact.include?(ip)
                                                 end

                                                 if matched
                                                   interim = @interim_statuses[matched]
                                                   port = interim.port.positive? ? interim.port : nil
                                                   ic << Routing::SuspendConnectRouting.new(ip, nil, nil, @bgd_id)
                                                   ic << Routing::SuspendConnectRouting.new(ip, port, nil, @bgd_id)
                                                   ie << Routing::SuspendExecuteRouting.new(ip, nil, nil, @bgd_id)
                                                   ie << Routing::SuspendExecuteRouting.new(ip, port, nil, @bgd_id)
                                                 else
                                                   ie << Routing::SuspendExecuteRouting.new(ip, nil, nil, @bgd_id)
                                                 end
                                               end

          Status.new(@bgd_id, Phase::IN_PROGRESS,
                     connect_routing: connect_routing + ip_connect,
                     execute_routing: execute_routing + ip_execute,
                     role_by_host: @host_mapper.role_by_host,
                     corresponding_hosts: @host_mapper.corresponding_hosts)
        end

        # PREPARATION: blue connects are routed to their current IP addresses to avoid
        # stale DNS resolving to the wrong host during the upcoming switchover.
        def preparation(rollback)
          return (rollback ? created : completed(rollback)) if @timer.expired?

          Status.new(@bgd_id, Phase::PREPARATION,
                     connect_routing: substitute_blue_with_ip_routing,
                     execute_routing: [],
                     role_by_host: @host_mapper.role_by_host,
                     corresponding_hosts: @host_mapper.corresponding_hosts)
        end

        private

        def post_connect_routing
          routing = []
          append_source_post_routing(routing)
          append_target_post_routing(routing)
          routing
        end

        # Builds source-side POST routing: redirects blue connects to corresponding green hosts.
        # If the green host isn't found yet, suspends until it appears.
        # Skipped once blue DNS has fully updated and all green hosts have changed their IAM name.
        def append_source_post_routing(routing)
          return if @switchover_state.blue_dns_update_completed || @iam_tracker.all_changed?

          @host_mapper.role_by_host.each do |blue_host, role|
            next if role != Role::SOURCE
            next unless @host_mapper.corresponding_hosts.key?(blue_host)

            host_pair       = @host_mapper.corresponding_hosts[blue_host]
            green_host_spec = host_pair&.[](1)
            interim_status  = @interim_statuses[role]
            port            = interim_status&.port&.positive? ? interim_status.port : nil
            is_instance     = Utils::RdsUtils.rds_instance?(blue_host)

            if green_host_spec.nil?
              routing << Routing::SuspendUntilCorrespondingHostFoundConnectRouting.new(blue_host, nil, role, @bgd_id)
              routing << Routing::SuspendUntilCorrespondingHostFoundConnectRouting.new(blue_host, port, role, @bgd_id) if port
            else
              green_host    = green_host_spec.host
              green_ip      = @host_mapper.host_ip_addresses[green_host]
              green_with_ip = green_ip ? Host::HostInfo.new(host: green_ip, port: green_host_spec.port,
                                                            role: green_host_spec.role) : green_host_spec
              iam_blue_host = Host::HostInfo.new(host: Utils::RdsUtils.remove_green_instance_prefix(green_host),
                                                 port: green_host_spec.port, role: green_host_spec.role)
              iam_hosts     = @iam_tracker.connected?(green_host, iam_blue_host.host) ? [iam_blue_host] : [green_host_spec, iam_blue_host]
              notify        = is_instance ? ->(h) { @iam_tracker.register(green_host, h) } : nil

              routing << Routing::SubstituteConnectRouting.new(blue_host, nil, role, green_with_ip, iam_hosts, notify)
              routing << Routing::SubstituteConnectRouting.new(blue_host, port, role, green_with_ip, iam_hosts, notify) if port
            end
          end
        end

        # Builds target-side POST routing:
        # - If green topology hasn't changed yet, reroutes green connects to their IP addresses.
        # - If green topology changed but DNS isn't removed yet, rejects new green connects.
        def append_target_post_routing(routing)
          if !@switchover_state.green_topology_changed
            @host_mapper.role_by_host.each do |green_host, role|
              next if role != Role::TARGET

              blue_host      = Utils::RdsUtils.remove_green_instance_prefix(green_host)
              interim_status = @interim_statuses[role]
              port           = interim_status&.port&.positive? ? interim_status.port : nil
              is_instance    = Utils::RdsUtils.rds_instance?(green_host)

              blue_host_spec  = Host::HostInfo.new(host: blue_host,  **({ port: port } if port).to_h)
              green_host_spec = Host::HostInfo.new(host: green_host, **({ port: port } if port).to_h)
              green_ip        = @host_mapper.host_ip_addresses[green_host]
              green_with_ip   = green_ip ? Host::HostInfo.new(host: green_ip,
                                                              **({ port: port } if port).to_h) : Host::HostInfo.new(host: green_host)
              iam_hosts       = @iam_tracker.connected?(green_host, blue_host) ? [blue_host_spec] : [green_host_spec, blue_host_spec]
              notify          = is_instance ? ->(h) { @iam_tracker.register(green_host, h) } : nil

              routing << Routing::SubstituteConnectRouting.new(green_host, nil, role, green_with_ip, iam_hosts, notify)
              routing << Routing::SubstituteConnectRouting.new(green_host, port, role, green_with_ip, iam_hosts, notify) if port
            end
          elsif !@switchover_state.green_dns_removed
            routing << Routing::RejectConnectRouting.new(nil, nil, Role::TARGET)
          end
        end

        # Builds PREPARATION routing: substitutes blue hostname connects with their resolved IP
        # addresses so connections bypass DNS during the switchover window.
        def substitute_blue_with_ip_routing
          @host_mapper.role_by_host.flat_map do |host, role|
            next [] if role != Role::SOURCE

            host_pair = @host_mapper.corresponding_hosts[host]
            next [] if host_pair.nil?

            blue_host_spec    = host_pair[0]
            blue_ip_entry     = @host_mapper.host_ip_addresses[blue_host_spec.host]
            blue_ip_host_spec = blue_ip_entry ? Host::HostInfo.new(host: blue_ip_entry, port: blue_host_spec.port,
                                                                   role: blue_host_spec.role) : blue_host_spec

            entries = [Routing::SubstituteConnectRouting.new(host, nil, role, blue_ip_host_spec, [blue_host_spec], nil)]

            interim_status = @interim_statuses[role]
            if interim_status
              port = interim_status.port.positive? ? interim_status.port : nil
              entries << Routing::SubstituteConnectRouting.new(host, port, role, blue_ip_host_spec, [blue_host_spec], nil) if port
            end

            entries
          end
        end
      end
    end
  end
end
