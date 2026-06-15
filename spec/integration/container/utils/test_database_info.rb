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

require_relative 'test_instance_info'

module Integration
  class TestDatabaseInfo
    attr_reader :username, :password, :default_dbname,
                :cluster_endpoint, :cluster_endpoint_port,
                :cluster_read_only_endpoint, :cluster_read_only_endpoint_port,
                :instance_endpoint_suffix, :instance_endpoint_port,
                :instances

    def initialize(database_info)
      return if database_info.nil?

      @username = database_info['username']
      @password = database_info['password']
      @default_dbname = database_info['defaultDbName']
      @cluster_endpoint = database_info['clusterEndpoint']
      @cluster_endpoint_port = database_info['clusterEndpointPort']
      @cluster_read_only_endpoint = database_info['clusterReadOnlyEndpoint']
      @cluster_read_only_endpoint_port = database_info['clusterReadOnlyEndpointPort']
      @instance_endpoint_suffix = database_info['instanceEndpointSuffix']
      @instance_endpoint_port = database_info['instanceEndpointPort']
      @instances = Array(database_info['instances']).compact.map { |i| TestInstanceInfo.new(i) }
    end

    def instance(instance_id)
      @instances.find { |i| i.instance_id == instance_id } ||
        raise("Instance #{instance_id} not found.")
    end

    def move_instance_first(instance_id)
      return if instance_id.nil?

      idx = @instances.index { |i| i.instance_id == instance_id } || raise("Instance #{instance_id} not found.")
      @instances.unshift(@instances.delete_at(idx))
    end
  end
end
