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
require 'aws_advanced_ruby_driver_wrapper/utils/parser/encryption_annotation_parser'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::Parser::EncryptionAnnotationParser do
  subject { described_class }

  describe '.parse_annotations' do
    it 'returns a 1-based index map for a single annotation on the second param' do
      sql = 'INSERT INTO users (name, ssn) VALUES (?, /*@encrypt:users.ssn*/ ?)'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    it 'maps multiple annotations to their correct 1-based indices' do
      sql = 'INSERT INTO users (ssn, credit_card, email) VALUES (/*@encrypt:users.ssn*/ ?, /*@encrypt:users.credit_card*/ ?, ?)'
      expect(subject.parse_annotations(sql)).to eq({ 1 => 'users.ssn', 2 => 'users.credit_card' })
    end

    it 'handles annotation in UPDATE SET clause' do
      sql = 'UPDATE users SET name = ?, ssn = /*@encrypt:users.ssn*/ ? WHERE id = ?'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    it 'returns empty hash when there are no annotations' do
      expect(subject.parse_annotations('INSERT INTO users (name, email) VALUES (?, ?)')).to eq({})
    end

    it 'handles schema-qualified column names' do
      sql = 'INSERT INTO public.users (ssn) VALUES (/*@encrypt:public.users.ssn*/ ?)'
      expect(subject.parse_annotations(sql)).to eq({ 1 => 'public.users.ssn' })
    end

    it 'handles underscores in column names' do
      sql = 'INSERT INTO users (credit_card_number) VALUES (/*@encrypt:users.credit_card_number*/ ?)'
      expect(subject.parse_annotations(sql)).to eq({ 1 => 'users.credit_card_number' })
    end

    it 'handles multiline queries' do
      sql = "INSERT INTO users (name, ssn, email)\nVALUES (\n  ?,\n  /*@encrypt:users.ssn*/ ?,\n  ?\n)"
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    it 'handles INSERT...SELECT' do
      sql = 'INSERT INTO orders (user_id, payment_info, amount) SELECT id, /*@encrypt:orders.payment_info*/ ?, total FROM temp WHERE id = ?'
      expect(subject.parse_annotations(sql)).to eq({ 1 => 'orders.payment_info' })
    end

    it 'handles MySQL backtick identifiers' do
      sql = 'INSERT INTO `users` (`name`, `ssn`) VALUES (?, /*@encrypt:users.ssn*/ ?)'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    it 'handles ON DUPLICATE KEY with multiple annotations' do
      sql = 'INSERT INTO `users` (`id`, `ssn`) VALUES (?, /*@encrypt:users.ssn*/ ?) ' \
            'ON DUPLICATE KEY UPDATE `ssn` = /*@encrypt:users.ssn*/ ?'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn', 3 => 'users.ssn' })
    end

    it 'returns empty hash for nil' do
      expect(subject.parse_annotations(nil)).to eq({})
    end

    it 'returns empty hash for empty string' do
      expect(subject.parse_annotations('')).to eq({})
    end
  end

  describe '.strip_annotations' do
    it 'removes a single annotation and preserves the ? placeholder' do
      sql = 'INSERT INTO users (ssn) VALUES (/*@encrypt:users.ssn*/ ?)'
      expect(subject.strip_annotations(sql)).to eq('INSERT INTO users (ssn) VALUES (?)')
    end

    it 'removes multiple annotations' do
      sql = 'INSERT INTO users (ssn, cc) VALUES (/*@encrypt:users.ssn*/ ?, /*@encrypt:users.cc*/ ?)'
      expect(subject.strip_annotations(sql)).to eq('INSERT INTO users (ssn, cc) VALUES (?, ?)')
    end

    it 'handles extra whitespace between annotation and ?' do
      sql = 'INSERT INTO users (ssn) VALUES (/*@encrypt:users.ssn*/   ?)'
      expect(subject.strip_annotations(sql)).to eq('INSERT INTO users (ssn) VALUES (?)')
    end

    it 'returns the sql unchanged when there are no annotations' do
      sql = 'INSERT INTO users (name) VALUES (?)'
      expect(subject.strip_annotations(sql)).to eq(sql)
    end

    it 'does not leave @encrypt in the result' do
      sql = 'INSERT INTO `users` (`ssn`) VALUES (/*@encrypt:users.ssn*/ ?)'
      expect(subject.strip_annotations(sql)).not_to include('@encrypt')
    end

    it 'returns nil for nil input' do
      expect(subject.strip_annotations(nil)).to be_nil
    end

    it 'returns empty string for empty input' do
      expect(subject.strip_annotations('')).to eq('')
    end
  end

  describe '.annotations?' do
    it 'returns true when an annotation is present' do
      expect(subject.annotations?('INSERT INTO users (ssn) VALUES (/*@encrypt:users.ssn*/ ?)')).to be true
    end

    it 'returns false when no annotation is present' do
      expect(subject.annotations?('INSERT INTO users (name) VALUES (?)')).to be false
    end

    it 'returns false for nil' do
      expect(subject.annotations?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(subject.annotations?('')).to be false
    end
  end
end
