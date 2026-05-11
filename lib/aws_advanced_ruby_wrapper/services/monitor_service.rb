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

require 'singleton'

module AwsAdvancedRubyWrapper
  module Services
    class MonitorService
      include Singleton

      def initialize
        @monitors = []
        @connections = []
        @shutdown_service = AwsAdvancedRubyWrapper.shutdown_service
        @shutdown_service.register(self)
      end

      def shutdown(grace_period:)
        deadline = Time.now + grace_period

        @shutdown_service.shutdown_threads(@monitors, deadline)
        @shutdown_service.close_connections(@connections, deadline)
      end
    end
  end
end
