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

require_relative '../failover_plugin'
require_relative '../../errors'
require_relative '../../host/host_role'
require_relative '../../property_definition'
require_relative '../../utils/accessible_regions'
require_relative '../../utils/rds_utils'
require_relative '../../utils/rds_url_type'
require_relative 'gdb_failover_mode'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Gdb
      # Failover plugin for Global Aurora Databases.
      #
      # Unlike {FailoverPlugin}, which always targets the same role, this plugin picks its target
      # based on the region of the cluster that is currently the GDB primary. Two modes are
      # configured: +active_home_failover_mode+ applies while the primary region is the home region,
      # and +inactive_home_failover_mode+ applies while it is not. Both accept any of the modes in
      # {GdbFailoverMode}.
      #
      # The home region is taken from +failover_home_region+, or derived from the initial endpoint
      # when that endpoint carries a region. When +accessible_regions+ is set, hosts outside those
      # regions are never selected.
      class GdbFailoverPlugin < FailoverPlugin
        def initialize(service_container, props = ::Concurrent::Map.new)
          super

          # The inherited @failover_mode is unused in this class; @active_home_failover_mode and
          # @inactive_home_failover_mode are consulted instead.
          @active_home_failover_mode = nil
          @inactive_home_failover_mode = nil
          @home_region = nil
          @accessible_regions = nil
        end

        private

        def init_failover_mode
          return unless @rds_url_type.nil?

          initial_host = connection_service.initial_host_info
          @rds_url_type = Utils::RdsUtils.identify_rds_type(initial_host&.host)
          reject_rds_proxy_endpoint

          @home_region = resolve_home_region(initial_host)
          @accessible_regions = Utils::AccessibleRegions.parse(@wrapper_props)

          if @accessible_regions && !@accessible_regions.include?(@home_region.downcase)
            raise Errors::AwsError,
                  "Home region '#{@home_region}' is not included in the list of accessible regions " \
                  "#{@accessible_regions.to_a}. The home region must be accessible."
          end

          @active_home_failover_mode = resolve_failover_mode(PropertyDefinition::ACTIVE_HOME_FAILOVER_MODE)
          @inactive_home_failover_mode = resolve_failover_mode(PropertyDefinition::INACTIVE_HOME_FAILOVER_MODE)

          logger.debug do
            "failover_home_region=#{@home_region}, accessible_regions=#{@accessible_regions&.to_a}, " \
              "active_home_failover_mode=#{@active_home_failover_mode}, " \
              "inactive_home_failover_mode=#{@inactive_home_failover_mode}"
          end
        end

        # @return [String] the configured home region, or the region of the initial endpoint
        # @raise [Errors::AwsError] if no home region is configured and none can be derived
        def resolve_home_region(initial_host)
          configured = PropertyDefinition::FAILOVER_HOME_REGION.get_string(@wrapper_props)
          return configured unless configured.nil? || configured.strip.empty?

          derived = @rds_url_type&.region? ? Utils::RdsUtils.rds_region(initial_host&.host) : nil
          if derived.nil? || derived.empty?
            raise Errors::AwsError,
                  'A failover home region should be provided. The home region could not be determined from the ' \
                  "connection endpoint, so it must be set via the '#{PropertyDefinition::FAILOVER_HOME_REGION.name}' property."
          end

          derived
        end

        # Resolves one of the two configured modes, defaulting based on the initial endpoint type.
        #
        # @param property [WrapperProperty]
        # @return [Symbol] one of the {GdbFailoverMode} constants
        def resolve_failover_mode(property)
          configured = GdbFailoverMode.from_value(property.get_string(@wrapper_props))
          return configured unless configured.nil?

          if [Utils::RdsUrlType::RDS_WRITER_CLUSTER, Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER].include?(@rds_url_type)
            GdbFailoverMode::STRICT_WRITER
          else
            GdbFailoverMode::HOME_READER_OR_WRITER
          end
        end

        def strict_writer_failover_mode?
          current_failover_mode(Utils::RdsUtils.rds_region(connection_service.current_host_info&.host)) ==
            GdbFailoverMode::STRICT_WRITER
        end

        # The mode that applies given the region of the current GDB primary.
        #
        # @param primary_region [String, nil] the region the primary writer is in
        # @return [Symbol] one of the {GdbFailoverMode} constants
        def current_failover_mode(primary_region)
          home_region?(primary_region) ? @active_home_failover_mode : @inactive_home_failover_mode
        end

        def home_region?(region)
          !region.nil? && @home_region.casecmp?(region)
        end

        # Whether a host is in one of the accessible regions. All hosts are accessible when no
        # region restriction is configured.
        #
        # @param host_info [Host::HostInfo]
        # @return [Boolean]
        def accessible_region?(host_info)
          return true if @accessible_regions.nil?

          region = Utils::RdsUtils.rds_region(host_info.host)
          !region.nil? && @accessible_regions.include?(region.downcase)
        end

        def failover
          if @closed_explicitly
            logger.debug { 'Connection was explicitly closed, skipping failover' }
            return
          end

          failover_start = Time.now
          failover_deadline = failover_start + @failover_timeout

          logger.info { 'Starting failover' }

          # This is expected to return once the topology has stabilized, i.e. once the cluster
          # control plane has already chosen a new writer.
          unless host_service.force_refresh_host_list?(verify_writer: true, timeout_sec: @failover_timeout)
            raise Errors::FailoverFailedError, 'The request to discover the new topology timed out or was unsuccessful'
          end

          writer_candidate = host_service.all_hosts.find { |h| h.role == Host::HostRole::WRITER }
          if writer_candidate.nil?
            raise Errors::FailoverFailedError,
                  "Unable to find a writer in the updated host list: #{host_service.all_hosts.map(&:url)}"
          end

          writer_region = Utils::RdsUtils.rds_region(writer_candidate.host)
          mode = current_failover_mode(writer_region)
          logger.debug do
            "GDB primary region is home region: #{home_region?(writer_region)}. Failover mode in effect: #{mode}"
          end

          if mode == GdbFailoverMode::STRICT_WRITER
            failover_to_writer(writer_candidate, writer_region, failover_deadline)
          else
            failover_to_allowed_host(mode, failover_deadline)
          end
        ensure
          duration_ms = ((Time.now - failover_start) * 1000).round if failover_start
          logger.debug { "Failover duration: #{duration_ms}ms" } if duration_ms
        end

        def failover_to_writer(writer_candidate, writer_region, deadline)
          unless accessible_region?(writer_candidate)
            raise Errors::FailoverFailedError,
                  "Writer is in region '#{writer_region}' which is not in the list of accessible regions " \
                  "#{@accessible_regions.to_a}."
          end

          was_in_transaction = @service_container.session_state_service.in_transaction?
          result = nil
          success = false

          begin
            result = @retry_util.connect_to_writer(self, @service_container.plugin_manager, deadline: deadline)
            success = true
            connection_service.update_current_connection(result.connection, result.host_info)
            raise_failover_success_error(was_in_transaction)
          rescue Timeout::Error
            raise Errors::FailoverFailedError,
                  "Failover timed out after #{@failover_timeout}s. " \
                  "Unable to connect to the new writer #{writer_candidate.host}."
          ensure
            close_quietly(result&.connection) unless success
          end
        end

        def failover_to_allowed_host(mode, deadline)
          was_in_transaction = @service_container.session_state_service.in_transaction?
          result = nil
          success = false

          begin
            result = @retry_util.connect_to_allowed_host(
              self,
              @service_container.plugin_manager,
              verify_role: verify_role_for(mode),
              strategy: @reader_selector_strategy,
              deadline: deadline
            ) { allowed_hosts_for(mode) }
            success = true
            connection_service.update_current_connection(result.connection, result.host_info)
            raise_failover_success_error(was_in_transaction)
          rescue Timeout::Error
            raise Errors::FailoverFailedError,
                  "Failover timed out after #{@failover_timeout}s. Unable to connect to a host allowed by failover mode #{mode}."
          ensure
            close_quietly(result&.connection) unless success
          end
        end

        # The role a new connection must report, or nil when either role is acceptable.
        #
        # @param mode [Symbol] one of the {GdbFailoverMode} constants
        # @return [Symbol, nil]
        def verify_role_for(mode)
          case mode
          when GdbFailoverMode::STRICT_HOME_READER,
               GdbFailoverMode::STRICT_OUT_OF_HOME_READER,
               GdbFailoverMode::STRICT_ANY_READER
            Host::HostRole::READER
          end
        end

        # The hosts that may be connected to under the given mode. Recomputed on every retry so that
        # a refreshed topology is picked up.
        #
        # @param mode [Symbol] one of the {GdbFailoverMode} constants
        # @return [Array<Host::HostInfo>]
        def allowed_hosts_for(mode)
          hosts = host_service.hosts.select { |host| host_allowed?(host, mode) }
          hosts.select { |host| accessible_region?(host) }
        end

        def host_allowed?(host, mode)
          reader = host.role == Host::HostRole::READER
          writer = host.role == Host::HostRole::WRITER

          # A host whose region cannot be determined is neither in nor out of the home region, so it
          # is not eligible for any of the region-specific modes.
          region = Utils::RdsUtils.rds_region(host.host)
          home = home_region?(region)
          out_of_home = !region.nil? && !home

          case mode
          when GdbFailoverMode::STRICT_HOME_READER then reader && home
          when GdbFailoverMode::STRICT_OUT_OF_HOME_READER then reader && out_of_home
          when GdbFailoverMode::STRICT_ANY_READER then reader
          when GdbFailoverMode::HOME_READER_OR_WRITER then writer || (reader && home)
          when GdbFailoverMode::OUT_OF_HOME_READER_OR_WRITER then writer || (reader && out_of_home)
          when GdbFailoverMode::ANY_READER_OR_WRITER then true
          else raise Errors::AwsError, "Unsupported global database failover mode: #{mode}"
          end
        end

        # @raise [NotImplementedError] always; see {#failover} for this plugin's implementation
        def failover_reader
          raise NotImplementedError, "#{self.class} performs failover via #failover"
        end

        # @raise [NotImplementedError] always; see {#failover} for this plugin's implementation
        def failover_writer
          raise NotImplementedError, "#{self.class} performs failover via #failover"
        end
      end
    end
  end
end
