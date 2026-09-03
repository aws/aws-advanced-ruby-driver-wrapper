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

require_relative 'test_database_info'
require_relative 'test_environment_request'
require_relative 'test_proxy_database_info'
require_relative 'test_telemetry_info'

module Integration
  class TestEnvironmentInfo
    attr_reader :request,
                :aws_access_key_id,
                :aws_secret_access_key,
                :aws_session_token,
                :region,
                :rds_endpoint,
                :dbname,
                :iam_user_name,
                :bg_deployment_id,
                :cluster_parameter_group,
                :random_base,
                :database_info,
                :proxy_database_info,
                :traces_telemetry_info,
                :metrics_telemetry_info,
                :global_cluster_endpoint,
                :global_cluster_identifier,
                :primary_region,
                :secondary_region,
                :secondary_cluster_endpoint,
                :secondary_cluster_identifier,
                :secondary_database_info,
                :secondary_proxy_database_info

    def initialize(test_info)
      return if test_info.nil?

      @request = TestEnvironmentRequest.new(test_info['request']) if test_info['request']
      @aws_access_key_id = test_info['awsAccessKeyId']
      @aws_secret_access_key = test_info['awsSecretAccessKey']
      @aws_session_token = test_info['awsSessionToken']
      @region = test_info['region']
      @rds_endpoint = test_info['rdsEndpoint']
      @dbname = test_info['rdsDbName']
      @iam_user_name = test_info['iamUsername']
      @bg_deployment_id = test_info['blueGreenDeploymentId']
      @cluster_parameter_group = test_info['clusterParameterGroupName']
      @random_base = test_info['randomBase']
      @database_info = TestDatabaseInfo.new(test_info['databaseInfo']) if test_info['databaseInfo']
      @proxy_database_info = TestProxyDatabaseInfo.new(test_info['proxyDatabaseInfo']) if test_info['proxyDatabaseInfo']
      @traces_telemetry_info = TestTelemetryInfo.new(test_info['tracesTelemetryInfo']) if test_info['tracesTelemetryInfo']
      @metrics_telemetry_info = TestTelemetryInfo.new(test_info['metricsTelemetryInfo']) if test_info['metricsTelemetryInfo']
      @global_cluster_endpoint = test_info['globalClusterEndpoint']
      @global_cluster_identifier = test_info['globalClusterIdentifier']
      @primary_region = test_info['primaryRegion']
      @secondary_region = test_info['secondaryRegion']
      @secondary_cluster_endpoint = test_info['secondaryClusterEndpoint']
      @secondary_cluster_identifier = test_info['secondaryClusterIdentifier']
      @secondary_database_info = TestDatabaseInfo.new(test_info['secondaryDatabaseInfo']) if test_info['secondaryDatabaseInfo']
      return unless test_info['secondaryProxyDatabaseInfo']

      @secondary_proxy_database_info = TestProxyDatabaseInfo.new(test_info['secondaryProxyDatabaseInfo'])
    end
  end
end
