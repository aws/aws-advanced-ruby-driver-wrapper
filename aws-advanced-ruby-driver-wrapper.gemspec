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
  # TODO: uncomment URIs
  # spec.homepage = 'github.com/aws/aws-advanced-ruby-driver-wrapper'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.3.0'

  # spec.metadata['homepage_uri'] = spec.homepage
  # spec.metadata['source_code_uri'] = 'github.com/aws/aws-advanced-ruby-driver-wrapper'
  # spec.metadata['changelog_uri'] = 'github.com/aws/aws-advanced-ruby-driver-wrapper/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  # Prefer `git ls-files` for an accurate, tracked-file list, but fall back to a
  # pure-Ruby directory glob when git is unavailable (e.g. inside a build/test
  # container where the .git directory is not present). This keeps `bundle install`
  # from emitting "fatal: not a git repository" and works identically offline.
  spec.files = Dir.chdir(__dir__) do
    in_git_repo =
      File.directory?(File.join(__dir__, '.git')) &&
      begin
        system('git', 'rev-parse', '--is-inside-work-tree',
               out: File::NULL, err: File::NULL)
      rescue StandardError
        false
      end

    tracked =
      if in_git_repo
        `git ls-files -z`.split("\x0")
      else
        Dir.glob('**/*', File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
      end

    tracked.reject do |f|
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
