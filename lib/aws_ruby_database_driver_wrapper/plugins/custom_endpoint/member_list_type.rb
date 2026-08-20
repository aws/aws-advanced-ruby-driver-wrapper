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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module CustomEndpoint
      # Represents the member list type of a custom endpoint.
      # Used with a member list to determine which instances are included or excluded.
      module MemberListType
        # Only the listed instances are included. New cluster instances are NOT auto-added.
        STATIC_LIST = :static_list

        # The listed instances are excluded. New cluster instances ARE auto-added.
        EXCLUSION_LIST = :exclusion_list
      end
    end
  end
end
