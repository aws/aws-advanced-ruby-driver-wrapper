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

require_relative 'lib/aws_advanced_ruby_driver_wrapper/version'

Gem::Specification.new do |spec|
  spec.name = 'aws-advanced-ruby-driver-wrapper'
  spec.version = AwsAdvancedRubyDriverWrapper::VERSION
  spec.authors = ['Amazon Web Services']

  spec.summary = 'AWS Advanced Ruby Driver Wrapper for MySQL and PostgreSQL'
  spec.description = 'A Ruby DB driver wrapper that provides enhanced features for AWS RDS MySQL/PostgreSQL databases'
  spec.homepage = 'https://github.com/aws/aws-advanced-ruby-driver-wrapper'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri'] = 'https://github.com/aws/aws-advanced-ruby-driver-wrapper'
  spec.metadata['changelog_uri'] = 'https://github.com/aws/aws-advanced-ruby-driver-wrapper/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files ship in the released gem via an explicit allow-list: the
  # runtime library plus the top-level legal/informational files. An allow-list is
  # used deliberately so packaging never depends on git being present and can never
  # sweep up unrelated files that happen to sit in the build directory (local
  # credentials, logs, editor state, previously built gems, etc.).
  spec.files = Dir.chdir(__dir__) do
    root_files = %w[
      LICENSE
      NOTICE
      README.md
      CHANGELOG.md
      aws-advanced-ruby-driver-wrapper.gemspec
    ]

    Dir.glob('lib/**/*', File::FNM_DOTMATCH).reject { |f| File.directory?(f) } +
      root_files.select { |f| File.file?(f) }
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'concurrent-ruby', '~> 1.3', '>= 1.3.7'

  spec.post_install_message = <<~MSG
    ═══════════════════════════════════════════════════════════════
    AWS Advanced Ruby Driver Wrapper installed successfully!

    To use with MySQL:
      gem install mysql2
      require 'aws_advanced_ruby_driver_wrapper/mysql'

    To use with PostgreSQL:
      gem install pg
      require 'aws_advanced_ruby_driver_wrapper/postgresql'

    Documentation: github.com/aws/aws-advanced-ruby-driver-wrapper
    ═══════════════════════════════════════════════════════════════
  MSG
end
