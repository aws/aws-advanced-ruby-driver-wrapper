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
  module Utils
    module Parser
      module QueryType
        SELECT  = :select
        INSERT  = :insert
        UPDATE  = :update
        DELETE  = :delete
        CREATE  = :create
        DROP    = :drop
        # A COPY that stores rows. It is a kind of its own rather than an INSERT because its values
        # reach the server as a stream instead of as bind parameters, so what a caller can do about
        # a column it writes is not the same.
        COPY    = :copy
        UNKNOWN = :unknown
      end
    end
  end
end
