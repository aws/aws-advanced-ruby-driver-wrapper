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
  # Centralized log messages for the wrapper. Mirrors the pattern from
  # aws-advanced-jdbc-wrapper's messages.properties.
  module LogMessages
    # Monitor
    MONITOR_STARTED = 'Started monitoring thread: %s'
    MONITOR_STOPPED = 'Stopped monitoring thread: %s'
    MONITOR_EXCEPTION = 'Exception in monitoring thread %s: %s'

    # MonitorService
    MONITOR_SERVICE_REMOVED_EXPIRED = 'Removed expired monitor: %s'
    MONITOR_SERVICE_REMOVED_ERROR = 'Removed monitor in error state: %s'
    MONITOR_SERVICE_TYPE_NOT_REGISTERED = 'Monitor type not registered: %s'

    # DriverDialect
    FAILED_TO_CLOSE_PG_CONNECTION = 'Failed to close PostgreSQL connection: %s'
    FAILED_TO_CLOSE_MYSQL_CONNECTION = 'Failed to close MySQL connection: %s'
  end
end
