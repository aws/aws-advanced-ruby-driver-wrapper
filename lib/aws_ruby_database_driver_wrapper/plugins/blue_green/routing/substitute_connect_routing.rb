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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      module Routing
        # Opens a new connection to a substitute host instead of the originally requested host.
        # When IAM auth is active and the substitute host is an IP address, each configured IAM
        # host is tried in turn so the IAM plugin can resolve the correct token hostname.
        class SubstituteConnectRouting
          include BaseRouting

          def initialize(host, port, role, substitute_host, iam_hosts, iam_successful_connect_notify = nil)
            @host = host
            @port = port
            @role = role
            @substitute_host = substitute_host
            @iam_hosts = iam_hosts
            @iam_successful_connect_notify = iam_successful_connect_notify
          end

          def to_s
            port_str = @port ? ":#{@port}" : ''
            iam_hosts_str = @iam_hosts&.map(&:host_and_port)&.join(', ') || '<null>'
            "#{self.class.name}@#{object_id.to_s(16)} [" \
              "#{@host}#{port_str}, " \
              "role: #{@role}, " \
              "substitute: #{@substitute_host&.host_and_port || '<null>'}, " \
              "iam_hosts: #{iam_hosts_str}]"
          end

          def apply(_host_info,
                    driver_props,
                    wrapper_props,
                    is_initial_connection,
                    service_container,
                    is_internal: false)
            plugin_manager = service_container.plugin_manager
            dialect_service = service_container.dialect_service

            unless Utils::RdsUtils.ip?(@substitute_host.host)
              return open_connection(plugin_manager, @substitute_host, driver_props, wrapper_props, is_initial_connection, is_internal)
            end

            # mysql2 uses :host for both socket connection and TLS CN verification.
            # Connecting to a raw IP with TLS active causes a CN mismatch.
            # Fall back to connecting via hostname (DNS will resolve to the correct IP post-switchover),
            # matching the effective behaviour of the Java/Go MySQL drivers which use the original
            # hostname for TLS regardless of the socket address.
            if driver_props[:sslca] && !plugin_manager.plugin_in_use?(Plugins::IamAuthPlugin)
              hostname_host = @substitute_host.deep_dup(host: @host)
              return open_connection(plugin_manager, hostname_host, driver_props, wrapper_props, is_initial_connection, is_internal)
            end

            if plugin_manager.plugin_in_use?(Plugins::IamAuthPlugin)
              if @iam_hosts.nil? || @iam_hosts.empty?
                raise StandardError,
                      'Connecting with IP address when IAM authentication is enabled requires an \'iam_host\' parameter.'
              end

              @iam_hosts.each do |iam_host|
                rerouted_host = @substitute_host.deep_dup
                rerouted_host.id = iam_host.id
                rerouted_host.availability = Host::HostAvailability::AVAILABLE

                rerouted_wrapper_props = wrapper_props.dup
                PropertyDefinition::IAM_HOST.set(rerouted_wrapper_props, iam_host.host)
                PropertyDefinition::IAM_PORT.set(rerouted_wrapper_props, iam_host.port.to_s) if iam_host.port_specified?

                begin
                  conn = plugin_manager.internal_connect(
                    rerouted_host,
                    driver_props,
                    rerouted_wrapper_props,
                    is_initial_connection
                  )
                  begin
                    @iam_successful_connect_notify&.call(iam_host.host)
                  rescue StandardError
                    nil
                  end
                  return conn
                rescue StandardError => e
                  raise unless dialect_service.login_error?(e)
                end
              end
              return nil
            end

            open_connection(plugin_manager, @substitute_host, driver_props, wrapper_props, is_initial_connection, is_internal)
          rescue StandardError => e
            raise unless dialect_service.login_error?(e)

            nil
          end

          private

          # Opens a connection through the plugin pipeline. Monitoring connections (is_internal: true)
          # must use internal_connect so they do NOT mutate the shared current connection — otherwise
          # one monitor thread's connect would close another monitor thread's live connection via
          # update_current_connection, causing a use-after-free segfault in the mysql2 C extension.
          def open_connection(plugin_manager, host, driver_props, wrapper_props, is_initial_connection, is_internal)
            if is_internal
              plugin_manager.internal_connect(host, driver_props, wrapper_props, is_initial_connection)
            else
              plugin_manager.connect(host, driver_props, is_initial_connection)
            end
          end
        end
      end
    end
  end
end
