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

# A simple result set wrapper that mimics database query results with fields and enumerable rows.
# Used in topology utils specs to avoid stubbing methods on plain arrays.
module ResultSetHelper
  ResultSet = Struct.new(:fields, :rows) do
    include Enumerable

    def each(&block)
      rows.each(&block)
    end

    def first
      rows.first
    end

    def empty?
      rows.empty?
    end

    def size
      rows.size
    end
  end

  def make_result_set(fields, rows)
    ResultSet.new(fields, rows)
  end
end
