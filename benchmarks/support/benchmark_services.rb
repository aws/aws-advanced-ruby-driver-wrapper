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

require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/ruby_method'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'

module AwsAdvancedRubyDriverWrapper
  module Benchmarks
    # Builds a service container backed by cheap, constant-cost stubs. The point of the benchmark is
    # to measure the plugin manager's pipeline overhead, so the services the plugins reach must do as
    # little as possible: any real work here would be measured as if it were the pipeline's cost.
    #
    # The stubs also cover what the real default plugins (initial connection strategy, failover) touch
    # on their happy path, so a chain of the actual default plugins can be benchmarked too.
    module BenchmarkServices
      # A single stand-in connection object. Plugins only need a non-nil value back, so any object
      # will do.
      STUB_CONNECTION = Object.new

      # A representative Aurora writer cluster endpoint. Using a real RDS endpoint (rather than a
      # bare hostname) means the RDS URL classification caches after the first call, matching how the
      # plugins behave in production instead of forcing an uncached regex sweep on every connect.
      REALISTIC_HOST = 'my-cluster.cluster-c9ukr8example.us-east-1.rds.amazonaws.com'

      # The methods the failover plugin treats as network-bound, and therefore subscribes to. Only the
      # execute pipeline the benchmark drives needs to be here for failover to wrap it.
      NETWORK_BOUND_METHODS = Set['connect', RubyMethod::CONNECTION_QUERY.name].freeze

      # Returns the stub connection instead of opening a real one, and reports connections as open.
      class StubDriverDialect
        def connect(_host_info, _driver_props)
          STUB_CONNECTION
        end

        def network_bound_methods
          NETWORK_BOUND_METHODS
        end

        def closed?(_connection)
          false
        end
      end

      # Reports every connection as a writer, so the failover plugin's writer-cluster verification
      # returns immediately instead of trying to redirect to a different instance.
      class StubDbDialect
        def host_role(_connection)
          Host::HostRole::WRITER
        end
      end

      class StubDialectService
        def driver_dialect
          @driver_dialect ||= StubDriverDialect.new
        end

        def db_dialect
          @db_dialect ||= StubDbDialect.new
        end

        def update_dialect(_connection); end
      end

      class StubConnectionService
        attr_reader :wrapper_props, :driver_props, :current_connection
        attr_accessor :initial_host_info

        def initialize(wrapper_props, current_connection: STUB_CONNECTION)
          @wrapper_props = wrapper_props
          @driver_props = {}
          @current_connection = current_connection
          @initial_host_info = Host::HostInfo.new(host: REALISTIC_HOST, port: '5432')
        end

        def multi_host_url?
          false
        end

        def pg?
          false
        end

        def current_host_info
          @initial_host_info
        end

        def update_current_connection(_connection, _host_info); end
      end

      class StubHostService
        def set_availability(_host_info, _availability); end

        def refresh_host_list; end

        def hosts
          []
        end

        def all_hosts
          []
        end
      end

      class StubSessionStateService
        def autocommit?
          false
        end

        def in_transaction?
          false
        end

        def update_transaction_state(_method_name, _args, _autocommit_before); end
      end

      # @param wrapper_props [Hash] connection properties, including the +wrapper_plugins+ code list
      # @param current_connection [Object] the object returned as the current connection, for
      #   benchmarks that drive a wrapper client over a fake driver connection
      # @return [Services::ServiceContainer] a container whose services are constant-cost stubs
      def self.container(wrapper_props, current_connection: STUB_CONNECTION)
        container = Services::ServiceContainer.new
        container.connection_service = StubConnectionService.new(wrapper_props, current_connection: current_connection)
        container.dialect_service = StubDialectService.new
        container.host_service = StubHostService.new
        container.session_state_service = StubSessionStateService.new
        container
      end
    end
  end
end
