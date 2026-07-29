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

require_relative '../../../spec_helper'
require 'aws_ruby_database_driver_wrapper/utils/parser/routing_hint_parser'
require 'aws_ruby_database_driver_wrapper/utils/parser/routing_hint'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHintParser do
  subject { described_class }

  describe '.parse_routing_hint' do
    it 'returns READER for a reader hint' do
      expect(subject.parse_routing_hint('/*@reader*/ SELECT * FROM users')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::READER)
    end

    it 'returns WRITER for a writer hint' do
      expect(subject.parse_routing_hint('/*@writer*/ SELECT * FROM users FOR UPDATE')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::WRITER)
    end

    it 'returns KEEP for a keep hint' do
      expect(subject.parse_routing_hint('/*@keep*/ SELECT * FROM users')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::KEEP)
    end

    it 'is case-insensitive' do
      expect(subject.parse_routing_hint('/*@READER*/ SELECT * FROM users')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::READER)
      expect(subject.parse_routing_hint('/*@Reader*/ SELECT * FROM users')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::READER)
    end

    it 'handles whitespace around the keyword' do
      expect(subject.parse_routing_hint('/* @reader */ SELECT * FROM users')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::READER)
      expect(subject.parse_routing_hint('/* @ reader */ SELECT * FROM users')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::READER)
    end

    it 'handles hint at end of sql' do
      expect(subject.parse_routing_hint('SELECT * FROM users /*@reader*/')).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::RoutingHint::READER)
    end

    it 'returns nil when there is no hint' do
      expect(subject.parse_routing_hint('SELECT * FROM users')).to be_nil
    end

    it 'returns nil for a regular block comment' do
      expect(subject.parse_routing_hint('/* just a comment */ SELECT * FROM users')).to be_nil
    end

    it 'returns nil for nil input' do
      expect(subject.parse_routing_hint(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(subject.parse_routing_hint('')).to be_nil
    end
  end

  describe '.strip_routing_hint' do
    it 'strips a reader hint' do
      expect(subject.strip_routing_hint('/*@reader*/ SELECT * FROM users')).to eq('SELECT * FROM users')
    end

    it 'strips a writer hint' do
      expect(subject.strip_routing_hint('/*@writer*/ SELECT * FROM users')).to eq('SELECT * FROM users')
    end

    it 'strips a keep hint' do
      expect(subject.strip_routing_hint('/*@keep*/ SELECT * FROM users')).to eq('SELECT * FROM users')
    end

    it 'is case-insensitive when stripping' do
      expect(subject.strip_routing_hint('/*@READER*/ SELECT * FROM users')).to eq('SELECT * FROM users')
    end

    it 'returns the sql unchanged when there is no hint' do
      sql = 'SELECT * FROM users'
      expect(subject.strip_routing_hint(sql)).to eq(sql)
    end

    it 'does not leave hint markers in the result' do
      result = subject.strip_routing_hint('/*@reader*/ SELECT * FROM users')
      expect(result).not_to match(/@reader|@writer|@keep/i)
    end

    it 'returns nil for nil input' do
      expect(subject.strip_routing_hint(nil)).to be_nil
    end

    it 'returns empty string for empty input' do
      expect(subject.strip_routing_hint('')).to eq('')
    end
  end
end
