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
      # configured: +in_home_failover_mode+ applies while the primary region is the home region,
      # and +out_of_home_failover_mode+ applies while it is not. Both accept any of the modes in
      # {GdbFailoverMode}.
      #
      # The home region is taken from +failover_home_region+, or derived from the initial endpoint
      # when that endpoint carries a region. When +accessible_regions+ is set, hosts outside those
      # regions are never selected.
      class GdbFailoverPlugin < FailoverPlugin
        def initialize(service_container, props = ::Concurrent::Map.new)
          super

          # The inherited @failover_mode is unused in this class; @in_home_failover_mode and
          # @out_of_home_failover_mode are consulted instead.
          @in_home_failover_mode = nil
          @out_of_home_failover_mode = nil
          @home_region = nil
          @accessible_regions = nil
          # Hosts whose region could not be determined, so that each is only logged once per failover.
          @regionless_hosts = Set.new
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

          @in_home_failover_mode = resolve_failover_mode(PropertyDefinition::IN_HOME_FAILOVER_MODE)
          @out_of_home_failover_mode = resolve_failover_mode(PropertyDefinition::OUT_OF_HOME_FAILOVER_MODE)

          logger.debug do
            "failover_home_region=#{@home_region}, accessible_regions=#{@accessible_regions&.to_a}, " \
              "in_home_failover_mode=#{@in_home_failover_mode}, " \
              "out_of_home_failover_mode=#{@out_of_home_failover_mode}"
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
                  "Unable to determine region from endpoint #{initial_host&.host}. If you are connecting via a global database " \
                  "endpoint or non-standard URL, please set the #{PropertyDefinition::FAILOVER_HOME_REGION.name} property."
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

        # Whether a read-only error should trigger failover, i.e. whether strict_writer is the mode
        # that currently applies.
        #
        # Which of the two configured modes applies depends on the region of the GDB primary, which is
        # not known yet: a read-only error is a sign that the primary has changed, so the latest known
        # topology may no longer say where it is. When only one of the modes is +strict_writer+ that mode
        # is assumed, so that a connection that has become read-only is not left as is. {#failover}
        # resolves the mode again once the new primary is known.
        #
        # @return [Boolean]
        def failover_on_read_only_error?
          in_home_strict_writer = @in_home_failover_mode == GdbFailoverMode::STRICT_WRITER
          out_of_home_strict_writer = @out_of_home_failover_mode == GdbFailoverMode::STRICT_WRITER
          return in_home_strict_writer if in_home_strict_writer == out_of_home_strict_writer

          logger.debug do
            configured = in_home_strict_writer ? 'in_home_failover_mode' : 'out_of_home_failover_mode'
            'A read-only error was encountered. Whether it triggers failover depends on whether the GDB primary is in ' \
              "the home region '#{@home_region}', which is not known yet because the error suggests the primary has " \
              "changed. #{configured}=#{GdbFailoverMode::STRICT_WRITER} is assumed so that the read-only connection is " \
              'not left as is, meaning failover will be triggered.'
          end

          true
        end

        # The mode that applies given the region of the current GDB primary.
        #
        # @param primary_region [String] the region the primary writer is in. Must not be nil - callers are
        #   responsible for handling endpoints whose region cannot be determined.
        # @return [Symbol] one of the {GdbFailoverMode} constants
        def current_failover_mode(primary_region)
          home_region?(primary_region) ? @in_home_failover_mode : @out_of_home_failover_mode
        end

        # Whether the given region is the home region.
        #
        # @param region [String] must not be nil; callers are responsible for handling endpoints
        #   whose region cannot be determined.
        # @return [Boolean]
        def home_region?(region)
          @home_region.casecmp?(region)
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
          @regionless_hosts.clear

          logger.info do
            "Starting global database failover from #{connection_service.current_host_info&.url || 'an unknown host'}. " \
              "accessible_regions=#{@accessible_regions.nil? ? 'all' : @accessible_regions.to_a}, " \
              "in_home_failover_mode=#{@in_home_failover_mode}, " \
              "out_of_home_failover_mode=#{@out_of_home_failover_mode}, " \
              "reader_host_selector_strategy=#{@reader_selector_strategy}, " \
              "failover_timeout_sec=#{@failover_timeout}"
          end

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
          if writer_region.nil? || writer_region.empty?
            # Unable to determine whether the writer is in-home or out-of-home. The writer usually stays in the same region during failover,
            # so we will assume the user connected to the home region and the writer stayed in-home.
            mode = @in_home_failover_mode
          else
            mode = current_failover_mode(writer_region)
          end

          log_failover_plan(writer_candidate, writer_region, mode)
          if mode == GdbFailoverMode::STRICT_WRITER
            failover_to_writer(writer_candidate, writer_region, failover_deadline)
          else
            failover_to_allowed_host(mode, failover_deadline)
          end
        ensure
          duration_ms = ((Time.now - failover_start) * 1000).round if failover_start
          logger.debug { "Failover duration: #{duration_ms}ms" } if duration_ms
        end

        # Explains which mode was chosen, and what the plugin will do with it.
        #
        # @param writer_candidate [Host::HostInfo] the writer the topology settled on
        # @param writer_region [String, nil] the region the new writer is in
        # @param mode [Symbol] one of the {GdbFailoverMode} constants
        def log_failover_plan(writer_candidate, writer_region, mode)
          if writer_region.nil?
            # Hosts in a GDB topology are built from the region-prefixed instance patterns in
            # global_cluster_instance_host_patterns, so they normally always carry a parseable
            # region. A writer that does not is a sign of a misconfigured pattern.
            logger.warn do
              "Unable to determine region of writer #{writer_candidate.host}. Please ensure you have set the " \
                "#{PropertyDefinition::GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS.name} setting. Failover will assume " \
                "in-home failover mode #{@in_home_failover_mode}."
            end

            return
          end

          logger.info do
            primary = if home_region?(writer_region)
                        "The GDB primary is now #{writer_candidate.url}, which is in the home region " \
                          "'#{@home_region}'. Using in_home_failover_mode=#{mode}."
                      else
                        "The GDB primary is now #{writer_candidate.url}, which is in region '#{writer_region}' " \
                          "rather than the home region '#{@home_region}'. Using out_of_home_failover_mode=#{mode}."
                      end

            "#{primary} #{failover_target_description(mode)}"
          end
        end

        # A plain-language description of the hosts the given mode will target.
        #
        # @param mode [Symbol] one of the {GdbFailoverMode} constants
        # @return [String]
        def failover_target_description(mode)
          case mode
          when GdbFailoverMode::STRICT_WRITER then 'Connecting to the new writer.'
          when GdbFailoverMode::STRICT_HOME_READER then "Connecting to a reader in the home region '#{@home_region}'."
          when GdbFailoverMode::STRICT_OUT_OF_HOME_READER then "Connecting to a reader outside the home region '#{@home_region}'."
          when GdbFailoverMode::STRICT_ANY_READER then 'Connecting to a reader in any region.'
          when GdbFailoverMode::HOME_READER_OR_WRITER then "Connecting to the writer or a reader in the home region '#{@home_region}'."
          when GdbFailoverMode::OUT_OF_HOME_READER_OR_WRITER
            "Connecting to the writer or a reader outside the home region '#{@home_region}'."
          when GdbFailoverMode::ANY_READER_OR_WRITER then 'Connecting to the writer or a reader in any region.'
          else "Connecting to a host allowed by failover mode #{mode}."
          end
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
            ) { |allowed_hosts| allowed_hosts_for(mode, allowed_hosts) }
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

        # The hosts that may be connected to under the given mode. Called on every retry with the
        # allowed hosts from the latest topology refresh.
        #
        # @param mode [Symbol] one of the {GdbFailoverMode} constants
        # @param allowed_hosts [Array<Host::HostInfo>] the current allowed hosts
        # @return [Array<Host::HostInfo>]
        def allowed_hosts_for(mode, allowed_hosts)
          hosts = allowed_hosts.select { |host| host_allowed?(host, mode) }
          hosts.select { |host| accessible_region?(host) }
        end

        def host_allowed?(host, mode)
          reader = host.role == Host::HostRole::READER
          writer = host.role == Host::HostRole::WRITER

          case mode
          when GdbFailoverMode::STRICT_HOME_READER then reader && region_position(host) == :in_home
          when GdbFailoverMode::STRICT_OUT_OF_HOME_READER then reader && region_position(host) == :out_of_home
          when GdbFailoverMode::STRICT_ANY_READER then reader
          when GdbFailoverMode::HOME_READER_OR_WRITER then writer || (reader && region_position(host) == :in_home)
          when GdbFailoverMode::OUT_OF_HOME_READER_OR_WRITER then writer || (reader && region_position(host) == :out_of_home)
          when GdbFailoverMode::ANY_READER_OR_WRITER then true
          else raise Errors::AwsError, "Unsupported global database failover mode: #{mode}"
          end
        end

        # Where the given host sits relative to the home region. Only consulted for modes that place
        # a region requirement on the host; +strict_any_reader+ and +any_reader_or_writer+ accept a
        # host regardless of its region and so never call this.
        #
        # @param host [Host::HostInfo]
        # @return [Symbol, nil] +:in_home+, +:out_of_home+, or nil if the region could not be determined
        def region_position(host)
          region = Utils::RdsUtils.rds_region(host.host)
          if region.nil? || region.empty?
            # This scenario is not expected: topology hosts are built from the region-prefixed instance patterns in
            # global_cluster_instance_host_patterns, so they should always carry a parseable region. Without one the
            # configured mode cannot be honoured for this host, so it is skipped. Only the first occurrence is logged,
            # since this method is called on every failover retry and the reason for the failure does not change.
            if @regionless_hosts.add?(host.host)
              logger.debug do
                "Unable to determine the region of #{host.host}, so it will not be considered an allowed host for the " \
                  'configured failover mode.'
              end
            end
            return nil
          end

          home_region?(region) ? :in_home : :out_of_home
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
