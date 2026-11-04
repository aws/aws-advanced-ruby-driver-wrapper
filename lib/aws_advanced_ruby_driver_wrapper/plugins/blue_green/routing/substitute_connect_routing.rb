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

module AwsAdvancedRubyDriverWrapper
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
            "#{self.class.name.split('::').last}@#{object_id.to_s(16)} [" \
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
                    is_internal: false,
                    bg_plugin: nil)
            plugin_manager = service_container.plugin_manager
            dialect_service = service_container.dialect_service
            driver_dialect = dialect_service.driver_dialect

            unless Utils::RdsUtils.ip?(@substitute_host.host)
              return open_connection(plugin_manager, @substitute_host, driver_props, wrapper_props, is_initial_connection, is_internal,
                                     bg_plugin)
            end

            # The substitute host is a raw IP, so a connection made by hostname could resolve (via DNS)
            # to the old instance during the switchover window. Connect to the IP directly instead.
            if plugin_manager.iam_token_plugin_in_use?
              return apply_iam(service_container, driver_props, wrapper_props, is_initial_connection, bg_plugin)
            end

            # pg can pin the socket to the IP (hostaddr) while keeping the original hostname for TLS
            # verification, so the pinned connection reaches the right instance and still passes
            # verify-full whatever the CA source.
            pinned_props = driver_dialect.props_pinned_to_ip(driver_props, @substitute_host.host)
            if pinned_props
              hostname_host = @substitute_host.deep_dup(host: @host)
              return open_connection(plugin_manager, hostname_host, pinned_props, wrapper_props, is_initial_connection, is_internal,
                                     bg_plugin)
            end

            # mysql2/trilogy use :host for both the socket and TLS CN verification, so connecting to a
            # raw IP with TLS active causes a CN mismatch. When TLS is active, fall back to the hostname
            # (DNS resolves to the correct IP post-switchover), matching the effective behaviour of the
            # Java/Go drivers which use the original hostname for TLS regardless of the socket address.
            if driver_props[driver_dialect.tls_ca_property_key]
              hostname_host = @substitute_host.deep_dup(host: @host)
              return open_connection(plugin_manager, hostname_host, driver_props, wrapper_props, is_initial_connection, is_internal,
                                     bg_plugin)
            end

            open_connection(plugin_manager, @substitute_host, driver_props, wrapper_props, is_initial_connection, is_internal, bg_plugin)
          rescue StandardError => e
            raise unless dialect_service.login_error?(e)

            nil
          end

          private

          # Connects to the substitute IP with IAM auth active, trying each configured IAM host in turn
          # so the IAM plugin can resolve the correct token hostname. pg pins the socket to the IP
          # (hostaddr) while presenting the IAM host name for TLS verification; the IAM token is still
          # generated for the IAM host via the IAM_HOST property. Other drivers connect to the IP as-is.
          def apply_iam(service_container, driver_props, wrapper_props, is_initial_connection, bg_plugin)
            plugin_manager = service_container.plugin_manager
            dialect_service = service_container.dialect_service
            driver_dialect = dialect_service.driver_dialect

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

              connect_props = driver_props
              pinned_props = driver_dialect.props_pinned_to_ip(driver_props, @substitute_host.host)
              if pinned_props
                connect_props = pinned_props
                rerouted_host = rerouted_host.deep_dup(host: iam_host.host)
              end

              begin
                conn = plugin_manager.internal_connect(
                  rerouted_host, connect_props, rerouted_wrapper_props, is_initial_connection, plugin_to_skip: bg_plugin
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
            nil
          end

          # Opens a connection through the plugin pipeline. Monitoring connections (is_internal: true)
          # must use internal_connect so they do NOT mutate the shared current connection — otherwise
          # one monitor thread's connect would close another monitor thread's live connection via
          # update_current_connection, causing a use-after-free segfault in the mysql2 C extension.
          #
          # bg_plugin is skipped in the nested pipeline so this substitute connection does not re-enter
          # BG routing. Without it, during the switchover window the opened connection matches the same
          # routing again and recurses until the stack overflows (SystemStackError).
          def open_connection(plugin_manager, host, driver_props, wrapper_props, is_initial_connection, is_internal, bg_plugin = nil)
            if is_internal
              plugin_manager.internal_connect(host, driver_props, wrapper_props, is_initial_connection, plugin_to_skip: bg_plugin)
            else
              plugin_manager.connect(host, driver_props, is_initial_connection, plugin_to_skip: bg_plugin)
            end
          end
        end
      end
    end
  end
end
