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

require_relative '../postgresql'

module ActiveRecord
  module ConnectionAdapters
    # Lets Action Cable's PostgreSQL subscription adapter (cable.yml `adapter: postgresql`) run on the
    # aws_postgresql adapter. Action Cable refuses any raw connection that is not a PG::Connection, and
    # aws_postgresql hands out a WrapperPgConnection, which forwards the calls Action Cable makes
    # (exec, escape_identifier, escape_string, wait_for_notify) to the PG::Connection it wraps.
    module AwsActionCablePostgreSQLSupport
      private

      def verify!(pg_conn)
        super unless pg_conn.is_a?(AwsAdvancedRubyDriverWrapper::WrapperPgConnection)
      end
    end
  end
end

# Action Cable runs this hook when its server loads, before it loads a subscription adapter, so the
# PostgreSQL one is loaded here to patch it. Applications without Action Cable never run the hook.
ActiveSupport.on_load(:action_cable) do
  require 'action_cable/subscription_adapter/postgresql'
  ActionCable::SubscriptionAdapter::PostgreSQL.prepend(ActiveRecord::ConnectionAdapters::AwsActionCablePostgreSQLSupport)
end
