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

require_relative 'test_environment'

module Integration
  module ConditionChecker
    # Skips the test if the current deployment is not in the requested list.
    #
    # @param requested_deployments [Array<DatabaseEngineDeployment>] the deployments for which this test should run
    def enable_on_deployments(*requested_deployments)
      env = TestEnvironment.current
      return if env.nil?

      current_deployment = env.deployment
      skip "This test is not supported for #{current_deployment} deployments" unless requested_deployments.include?(current_deployment)
    end

    # Skips the test if the current engine is not in the requested list.
    #
    # @param requested_engines [Array<DatabaseEngine>] the engines for which this test should run
    def enable_on_engines(*requested_engines)
      env = TestEnvironment.current
      return if env.nil?

      current_engine = env.engine
      skip "This test is not supported for #{current_engine}" unless requested_engines.include?(current_engine)
    end

    # Raises an error if the current deployment is not in the required list.
    # Use this instead of enable_on_deployments when running on the wrong deployment
    # Indicates a misconfiguration rather than an unsupported environment.
    #
    # @param required_deployments [Array<DatabaseEngineDeployment>] deployments on which this test must run
    def require_deployments(*required_deployments)
      env = Integration::TestEnvironment.current
      return if env.nil?

      current_deployment = env.deployment
      return if required_deployments.include?(current_deployment)

      raise "This test requires #{required_deployments.join(', ')} deployment(s) but current deployment is #{current_deployment}"
    end

    # Skips the test if the current engine is in the requested list.
    #
    # @param engines [Array<DatabaseEngine>] the engines for which this test should not run
    def disable_on_engines(*engines)
      env = TestEnvironment.current
      return if env.nil?

      current_engine = env.engine
      skip "This test is not supported for #{current_engine}" if engines.include?(current_engine)
    end

    # Skips the test if the instance count is outside the given min/max bounds.
    #
    # @param min_instances [Integer] minimum number of instances required, or -1 for no lower bound
    # @param max_instances [Integer] maximum number of instances allowed, or -1 for no upper bound
    def enable_on_num_instances(min_instances: -1, max_instances: -1)
      env = TestEnvironment.current
      return if env.nil?

      count = env.instances.size
      out_of_bounds = (min_instances > -1 && count < min_instances) ||
                      (max_instances > -1 && count > max_instances)
      skip "This test is not supported for test configurations with #{count} instances" if out_of_bounds
    end

    # Skips the test if any of the required features are missing from the current environment.
    #
    # @param enable_on_test_features [Array<TestEnvironmentFeatures>] features that must all be present for this test to run
    def enable_on_features(*enable_on_test_features)
      env = TestEnvironment.current
      return if env.nil?

      current_features = env.features
      missing = enable_on_test_features.reject { |f| current_features.include?(f) }
      skip 'The current test environment does not contain test features required for this test' if missing.any?
    end

    # Skips the test if any of the given features are present in the current environment.
    #
    # @param disable_on_test_features [Array<TestEnvironmentFeatures>] features that must not be present for this test to run
    def disable_on_features(*disable_on_test_features)
      env = TestEnvironment.current
      return if env.nil?

      current_features = env.features
      skip 'The current test environment contains test features for which this test is disabled' if
        disable_on_test_features.intersect?(current_features)
    end
  end
end
