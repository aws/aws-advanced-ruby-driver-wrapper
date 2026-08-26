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

# frozen_string_literal: true

require 'aws_ruby_driver_wrapper/plugins/blue_green/interim_status'
require 'aws_ruby_driver_wrapper/plugins/blue_green/phase'
require 'aws_ruby_driver_wrapper/plugins/blue_green/role'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'

# Helpers for building BlueGreenConnection objects in unit tests without a real DB connection.
# The key seam is InterimStatus — it is what StatusMonitor produces after querying the BG status
# table, and what StatusProvider#prepare_status consumes. Tests build InterimStatus directly and
# call prepare_status, bypassing all network I/O.
module BlueGreenHelpers
  BG = AwsRubyDriverWrapper::Plugins::BlueGreen
  Host = AwsRubyDriverWrapper::Host

  # Builds an InterimStatus for the given phase and role.
  #
  # Options:
  #   phase:                              BG::Phase constant (default NOT_CREATED)
  #   port:                               integer (default 3306)
  #   start_topology:                     array of HostInfo
  #   current_topology:                   array of HostInfo
  #   start_ip_addresses_by_host:         hash
  #   current_ip_addresses_by_host:       hash
  #   host_names:                         Set or array (converted to Set)
  #   all_start_topology_ip_changed:      bool (default false)
  #   all_start_topology_endpoints_removed: bool (default false)
  #   all_topology_changed:               bool (default false)
  def build_interim_status(
    phase: BG::Phase::NOT_CREATED,
    port: 3306,
    start_topology: nil,
    current_topology: nil,
    start_ip_addresses_by_host: {},
    current_ip_addresses_by_host: {},
    host_names: Set.new,
    all_start_topology_ip_changed: false,
    all_start_topology_endpoints_removed: false,
    all_topology_changed: false
  )
    BG::InterimStatus.new(
      phase,
      '1.0',
      port,
      start_topology,
      current_topology,
      start_ip_addresses_by_host,
      current_ip_addresses_by_host,
      Set[*host_names],
      all_start_topology_ip_changed,
      all_start_topology_endpoints_removed,
      all_topology_changed
    )
  end

  # Builds a minimal HostInfo for use in topology arrays.
  def host_info(host, role: Host::HostRole::WRITER, port: 3306)
    Host::HostInfo.new(host: host, port: port, role: role)
  end
end

RSpec.configure do |config|
  config.include BlueGreenHelpers, :blue_green
end
