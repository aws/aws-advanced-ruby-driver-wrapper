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

module Integration
  module TestEnvironmentFeatures
    IAM = :iam
    SECRETS_MANAGER = :secrets_manager
    FAILOVER_SUPPORTED = :failover_supported
    NETWORK_OUTAGES_ENABLED = :network_outages_enabled
    AWS_CREDENTIALS_ENABLED = :aws_credentials_enabled
    PERFORMANCE = :performance
    SKIP_MYSQL_DRIVER_TESTS = :skip_mysql_driver_tests
    SKIP_PG_DRIVER_TESTS = :skip_pg_driver_tests
    TELEMETRY_TRACES_ENABLED = :telemetry_traces_enabled
    TELEMETRY_METRICS_ENABLED = :telemetry_metrics_enabled
    BLUE_GREEN_DEPLOYMENT = :blue_green_deployment
  end
end
