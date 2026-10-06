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

require 'active_record'
require_relative '../services/service_utility'
require_relative '../host/rds_host_list_provider'

module ActiveRecord
  module ConnectionAdapters
    # Stops the wrapper's background monitors when ActiveRecord closes every connection pool, and forgets the
    # cached topology so that the next connection starts a new monitor straight away.
    #
    # The monitors keep their own connections to the database, outside ActiveRecord's pools. Closing
    # everything is what ActiveRecord does before another process takes over the database, for example
    # when bin/rails test runs db:test:prepare in a child process to drop and reload the test database,
    # and PostgreSQL refuses to drop a database that a monitor is still connected to. The next
    # connection that needs a monitor starts a new one.
    module AwsConnectionHandler
      def clear_all_connections!(...)
        super
        core = AwsAdvancedRubyDriverWrapper::Services::CoreServices
        core.monitor_service.stop_and_remove_all
        # Without this, connections would keep reading the cached topology with no monitor refreshing it.
        topology = AwsAdvancedRubyDriverWrapper::Host::RdsHostListProvider::TOPOLOGY_CACHE_NAME
        core.storage_service.clear(topology) if core.storage_service.registered?(topology)
      end
    end

    ConnectionHandler.prepend(AwsConnectionHandler)
  end
end
