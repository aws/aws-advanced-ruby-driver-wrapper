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
  module Errors
    class AwsError < StandardError
      attr_reader :connection_broken, :needs_reconfiguration

      def initialize(message, connection_broken: false, needs_reconfiguration: false)
        super(message)
        @needs_reconfiguration = needs_reconfiguration
        @connection_broken = connection_broken
      end
    end

    class FailoverFailedError < AwsError
      def initialize(message)
        super(message, connection_broken: true)
      end
    end

    class FailoverSuccessError < AwsError
      def initialize
        super(
          'The active SQL connection has changed due to a connection failure. Please re-configure session state if required.',
          needs_reconfiguration: true)
      end
    end

    class TransactionStateUnknownError < AwsError
      def initialize
        super(
          'Transaction resolution unknown. Please re-configure session state if required and retry the transaction.',
          connection_broken: true,
          needs_reconfiguration: true
        )
      end
    end

    # Raised by the connection_lifetime plugin when the connection reached its maximum lifetime and
    # is not usable. After the close action, every later call that reaches the database raises this
    # error too, until the connection is discarded or reset.
    class ConnectionLifetimeError < AwsError
      def initialize(message = 'The connection has reached its maximum lifetime and is closed.',
                     connection_broken: true, needs_reconfiguration: false)
        super
      end
    end

    # Raised by the connection_lifetime plugin when the connection reached its maximum lifetime and a
    # replacement connection could not be opened. The error that stopped the replacement is the cause.
    class ConnectionLifetimeFailedError < ConnectionLifetimeError
      def initialize
        super('Unable to open a replacement connection after the connection reached its maximum lifetime.')
      end
    end

    # Raised by the connection_lifetime plugin after it replaced a connection that reached its
    # maximum lifetime. The call that raised it was not run; session state set on the old connection
    # is gone, so set it again before retrying the call.
    class ConnectionLifetimeSuccessError < AwsError
      def initialize
        super(
          'The active SQL connection has changed because it reached its maximum lifetime. ' \
          'Please re-configure session state if required and retry the operation.',
          connection_broken: false,
          needs_reconfiguration: true
        )
      end
    end

    class IamAuthError < AwsError; end
    class SamlAuthError < AwsError; end
    class SecretsManagerAuthError < AwsError; end
    class PluginConflictError < AwsError; end
    class BlueGreenTimeoutError < AwsError; end
    class BlueGreenSwitchoverError < AwsError; end
  end
end
