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
  module Services
    # What a plugin can learn about, and change about, the call it is currently handling.
    #
    # A plugin's +execute+ already receives the arguments and the block of the call, but only as
    # copies: the pipeline reads what it hands to the next plugin from here, so a plugin that needs
    # to change them has to replace {#args} or {#block} rather than modify what it was given.
    # Likewise {#sql} is not always among the arguments, since a result method has no SQL of its
    # own and a prepared statement only carries the name it was prepared under.
    #
    # This context belongs to a single call on a single thread, and is reached through
    # {PluginManager#current_call_context}.
    class PluginCallContext
      # @return [String, nil] the SQL the call originated from, nil when the caller could not say
      attr_reader :sql

      # @return [Array] the arguments the target driver method will be called with
      attr_accessor :args

      # @return [Proc, nil] the block the target driver method will be called with
      attr_accessor :block

      # @param sql [String, nil]
      # @param args [Array]
      # @param block [Proc, nil]
      def initialize(sql, args, block = nil)
        @sql = sql
        @args = args
        @block = block
      end
    end
  end
end
