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
  module Utils
    module Telemetry
      # A gauge whose value is read from its callback each time metrics are collected.
      #
      # The instrument is registered once, and reads whichever callback was set last. The callback
      # can therefore be replaced, which a second registration of the same instrument would not do.
      class OpenTelemetryGauge
        attr_reader :name
        attr_writer :callback

        def initialize(meter, name)
          @name = name
          @callback = nil
          @gauge = meter.create_observable_gauge(name, callback: -> { @callback&.call })
        end
      end
    end
  end
end
