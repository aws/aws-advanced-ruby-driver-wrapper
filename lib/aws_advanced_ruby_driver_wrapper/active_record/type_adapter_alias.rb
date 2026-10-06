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

require 'active_record'

module AwsAdvancedRubyDriverWrapper
  # ActiveRecord's adapter-specific type registry (ActiveRecord::Type) keys every type
  # registration and lookup by the *config adapter name*. The wrapped adapters register nothing of
  # their own: they rely entirely on the vanilla PostgreSQL/Mysql2 adapters, which register their
  # OID / native types under adapter: :postgresql and adapter: :mysql2. A lookup for an
  # :aws_postgresql / :aws_mysql2 connection would therefore find none of them and raise
  # "Unknown type" for things like :interval, :point, array/range columns, or MySQL's
  # :unsigned_integer.
  #
  # Rather than copy the parent's registrations (which misses types registered after the adapter
  # loads, needs a duplicate guard, and reaches into the registry's private internals), alias the
  # wrapper adapter names to their parents at the two points ActiveRecord registers and resolves
  # types. Every lookup flows through Type.adapter_name_from, so mapping it there makes the wrapped
  # adapters resolve the exact same types as the vanilla ones, for all current and future types,
  # across Rails 7.2–8.1.
  #
  # Side effect: in an app that uses BOTH a plain postgresql and an aws_postgresql connection, a
  # type explicitly registered for :aws_postgresql is normalized to :postgresql and so also applies
  # to the plain postgresql connections (and vice versa). This is documented in the CHANGELOG.
  module TypeAdapterAlias
    ADAPTER_ALIASES = { aws_postgresql: :postgresql, aws_mysql2: :mysql2 }.freeze

    # Prepended onto ActiveRecord::Type's singleton class: normalizes the adapter name used for every
    # type lookup (attributes.rb resolves types via Type.adapter_name_from).
    module LookupAlias
      def adapter_name_from(model)
        name = super
        ADAPTER_ALIASES.fetch(name, name)
      end
    end

    # Prepended onto the registry: normalizes the adapter a type is registered under, so a type
    # registered explicitly for a wrapper adapter lands under the parent's key where lookups find it.
    module RegistryAlias
      def register(type_name, klass = nil, adapter: nil, **, &)
        super(type_name, klass, adapter: ADAPTER_ALIASES.fetch(adapter, adapter), **, &)
      end

      def add_modifier(options, klass, adapter: nil, **args)
        super(options, klass, adapter: ADAPTER_ALIASES.fetch(adapter, adapter), **args)
      end
    end
  end
end

ActiveRecord::Type.singleton_class.prepend(AwsAdvancedRubyDriverWrapper::TypeAdapterAlias::LookupAlias)
ActiveRecord::Type::AdapterSpecificRegistry.prepend(AwsAdvancedRubyDriverWrapper::TypeAdapterAlias::RegistryAlias)
