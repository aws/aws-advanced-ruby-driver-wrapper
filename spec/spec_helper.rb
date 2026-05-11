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

require 'simplecov'
require 'simplecov-cobertura'

SimpleCov.start do
  # Generate both HTML and XML formats
  SimpleCov.formatters =
    SimpleCov::Formatter::MultiFormatter.new(
      [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::CoberturaFormatter])

  # Filter out test files and vendor code from coverage analysis
  add_filter '/spec/'
  add_filter '/vendor/'

  # Only enforce coverage for files with complex business logic, eg:
  # add_group "Failover", "lib/plugins/failover"

  # TODO: decide on required coverage percentage and then uncomment the following line
  # minimum_coverage 80
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |f| require f }

require 'bundler/setup'
require 'aws_advanced_ruby_wrapper/postgresql'
require 'aws_advanced_ruby_wrapper/mysql'
require 'dotenv/load'
require 'pg'
require 'mysql2'
require 'active_record'
require 'aws_advanced_ruby_wrapper/activerecord/aws_mysql2_adapter'
require 'aws_advanced_ruby_wrapper/activerecord/aws_postgresql_adapter'

# Load environment variables for tests
Dotenv.load

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed
end
