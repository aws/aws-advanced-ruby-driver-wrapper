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
  PerfStat = Struct.new(:socket_timeout_sec, :network_outage_delay_ms, :min_ms, :max_ms, :avg_ms) do
    def self.csv_header
      'SocketTimeoutSec,NetworkOutageDelayMs,MinMs,MaxMs,AvgMs'
    end

    def to_csv_row
      "#{socket_timeout_sec},#{network_outage_delay_ms},#{min_ms},#{max_ms},#{avg_ms}"
    end
  end
end
