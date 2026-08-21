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

require_relative '../../../errors'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      module Routing
        # Rejects any attempt to open a new connection during a Blue/Green switchover.
        class RejectConnectRouting
          include BaseRouting

          def initialize(host, port, role)
            @host = host
            @port = port
            @role = role
          end

          def apply(*, **)
            raise Errors::BlueGreenSwitchoverError, 'Blue/Green Deployment switchover is in progress. New connection can\'t be opened.'
          end
        end
      end
    end
  end
end
