# frozen_string_literal: true

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'set'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Events
      # Event signaling that monitors for a cluster should be reset. Immediate delivery.
      class MonitorResetEvent
        attr_reader :cluster_id, :endpoints

        def initialize(cluster_id:, endpoints:)
          @cluster_id = cluster_id
          @endpoints = endpoints.freeze
          freeze
        end

        def immediate_delivery?
          true
        end
      end
    end
  end
end
