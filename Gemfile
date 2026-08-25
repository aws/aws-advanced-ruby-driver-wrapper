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

source 'https://rubygems.org'

gemspec

gem 'activerecord', '>= 7.2'
gem 'mysql2', '>= 0.5.7'
gem 'pg', '>= 1.6.3'
gem 'pg_query', '>= 5.1'

group :development do
  gem 'bundler'
  gem 'rdoc'
  gem 'rubocop', '~> 1.86'
  gem 'rubocop-performance', '~> 1.26'
  gem 'yard', '>= 0.9.44'
end

group :test do
  gem 'aws-sdk-rds', '~> 1.315.0'
  gem 'aws-sdk-secretsmanager'
  gem 'debug'
  gem 'dotenv'
  gem 'rspec'
  gem 'simplecov', require: false
  gem 'simplecov-cobertura', require: false
  gem 'toxiproxy'
end
