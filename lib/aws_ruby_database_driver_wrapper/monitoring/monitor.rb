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
  module Monitoring
    # Defines the contract for all monitors managed by MonitorService.
    module Monitor
      def start
        raise NotImplementedError
      end

      def monitor
        raise NotImplementedError
      end

      def stop
        raise NotImplementedError
      end

      def close; end

      def state
        raise NotImplementedError
      end

      def last_activity_nanos
        raise NotImplementedError
      end
    end
  end
end
