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

require 'set'
require_relative 'database_engine'
require_relative 'database_engine_deployment'
require_relative 'database_instances'
require_relative 'test_environment_features'

module Integration
  class TestEnvironmentRequest
    attr_reader :engine, :instances, :deployment, :num_of_instances, :features

    def initialize(request)
      return if request.nil?

      @engine = request['engine']&.downcase&.to_sym
      @instances = request['instances']&.downcase&.to_sym
      @deployment = request['deployment']&.downcase&.to_sym
      @num_of_instances = request['numOfInstances'] || 1
      @features = Set.new(Array(request['features']).map { |f| f.downcase.to_sym })
    end

    def display_name
      "Test environment [#{@deployment}, #{@engine}, #{@instances}, #{@num_of_instances}, #{@features}]"
    end
  end
end
