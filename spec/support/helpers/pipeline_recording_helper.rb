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

# Records the name every call entered the plugin pipeline under. It is the only plugin of its
# pipeline, so its pipeline callable is the target driver method and the arguments and the block it
# was given are handed straight to it.
class PipelineRecordingPlugin
  attr_reader :subscribed_methods, :method_names

  def initialize
    @subscribed_methods = Set['*']
    @method_names = []
  end

  def execute(method_name, target_callable, ...)
    @method_names << method_name
    target_callable.call(...)
  end
end

# Builds the wrapper internals that the driver wrapper classes need in order to take a call through
# the plugins, without connecting to anything.
module PipelineRecordingHelper
  # @param connection [Object] the driver connection the wrapper delegates to
  # @return [Array(Services::ServiceContainer, PipelineRecordingPlugin)]
  def build_recording_container(connection)
    plugin = PipelineRecordingPlugin.new
    manager = AwsAdvancedRubyDriverWrapper::Services::PluginManager.allocate
    manager.instance_variable_set(:@plugins, [plugin])
    manager.instance_variable_set(:@pipeline_cache, {})

    container = AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new
    container.plugin_manager = manager
    container.connection_service = instance_double(
      AwsAdvancedRubyDriverWrapper::Services::ConnectionService, current_connection: connection
    )

    [container, plugin]
  end

  # A stand-in for a driver result, which the wrappers recognize by class before wrapping it.
  #
  # @param result_class [Class] PG::Result or Mysql2::Result
  def driver_result(result_class, name)
    result = double(name)
    allow(result).to receive(:is_a?) { |klass| klass == result_class }
    result
  end
end

RSpec.configure { |config| config.include PipelineRecordingHelper }
