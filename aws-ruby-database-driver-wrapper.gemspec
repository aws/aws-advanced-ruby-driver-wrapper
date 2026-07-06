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

require_relative 'lib/aws_ruby_database_driver_wrapper/version'

Gem::Specification.new do |spec|
  spec.name = 'aws-ruby-database-driver-wrapper'
  spec.version = AwsRubyDatabaseDriverWrapper::VERSION
  spec.authors = ['Amazon Web Services']

  spec.summary = 'AWS Ruby Database Driver Wrapper for MySQL and PostgreSQL'
  spec.description = 'A Ruby DB driver wrapper that provides enhanced features for AWS RDS MySQL/PostgreSQL databases'
  # TODO: uncomment URIs
  # spec.homepage = 'github.com/aws/aws-ruby-database-driver-wrapper'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.3.0'

  # spec.metadata['homepage_uri'] = spec.homepage
  # spec.metadata['source_code_uri'] = 'github.com/aws/aws-ruby-database-driver-wrapper'
  # spec.metadata['changelog_uri'] = 'github.com/aws/aws-ruby-database-driver-wrapper/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'concurrent-ruby', '>= 1.3.7'

  spec.post_install_message = <<~MSG
    ═══════════════════════════════════════════════════════════════
    AWS Ruby Database Driver Wrapper installed successfully!

    To use with MySQL:
      gem install mysql2
      require 'aws_ruby_database_driver_wrapper/mysql'

    To use with PostgreSQL:
      gem install pg
      require 'aws_ruby_database_driver_wrapper/postgresql'

    Documentation: github.com/aws/aws-ruby-database-driver-wrapper
    ═══════════════════════════════════════════════════════════════
  MSG
end
