# frozen_string_literal: true

# Shim for Rails < 7.1 adapter resolution.
# Rails 7.0 resolves adapter: "aws_postgresql" by requiring
# "active_record/connection_adapters/aws_postgresql_adapter".
require 'aws_ruby_database_driver_wrapper/activerecord/aws_postgresql_adapter'
