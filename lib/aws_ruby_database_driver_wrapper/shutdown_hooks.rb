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

require_relative 'services/shutdown_service'

module AwsRubyDatabaseDriverWrapper
  @shutdown_hooks_registered = false

  # Registers signal traps and at_exit hooks for graceful shutdown.
  # Safe to call multiple times — hooks are only registered once.
  # Called automatically when a wrapper connection is first created.
  def self.ensure_shutdown_hooks_registered
    return if @shutdown_hooks_registered

    @shutdown_hooks_registered = true

    %w[TERM INT].each do |signal|
      trap(signal) do
        shutdown
        exit(0)
      end
    end

    at_exit { shutdown }
  end

  def self.shutdown_service
    @shutdown_service ||= Services::ShutdownService.instance
  end

  def self.shutdown(grace_period_sec: 10)
    puts 'calling shutdown...'
    shutdown_service.shutdown(grace_period_sec)
  end
end
