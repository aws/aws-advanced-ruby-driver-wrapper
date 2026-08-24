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
require 'aws_ruby_database_driver_wrapper/utils/parser/encryption_annotation_parser'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::Parser::EncryptionAnnotationParser do
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

    # pg numbers its placeholders, so the same annotation has to work in front of $n as well.
    it 'returns a 1-based index map for an annotation on a numbered placeholder' do
      sql = 'INSERT INTO users (name, ssn) VALUES ($1, /*@encrypt:users.ssn*/ $2)'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    # A numbered placeholder states its own position, so where it appears in the statement does not
    # have to match the parameter it stands for.
    it 'takes the index from the numbered placeholder rather than from its position' do
      sql = 'INSERT INTO users (ssn, name) VALUES (/*@encrypt:users.ssn*/ $2, $1)'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    it 'maps multiple numbered placeholders to their own indices' do
      sql = 'INSERT INTO users (ssn, credit_card, email) ' \
            'VALUES (/*@encrypt:users.ssn*/ $1, /*@encrypt:users.credit_card*/ $2, $3)'
      expect(subject.parse_annotations(sql)).to eq({ 1 => 'users.ssn', 2 => 'users.credit_card' })
    end

    it 'handles a numbered placeholder with more than one digit' do
      sql = "INSERT INTO users (#{Array.new(10) { |i| "c#{i}" }.join(', ')}, ssn) " \
            "VALUES (#{Array.new(10) { |i| "$#{i + 1}" }.join(', ')}, /*@encrypt:users.ssn*/ $11)"
      expect(subject.parse_annotations(sql)).to eq({ 11 => 'users.ssn' })
    end

    it 'handles an annotation on a numbered placeholder in an UPDATE SET clause' do
      sql = 'UPDATE users SET name = $1, ssn = /*@encrypt:users.ssn*/ $2 WHERE id = $3'
      expect(subject.parse_annotations(sql)).to eq({ 2 => 'users.ssn' })
    end

    it 'ignores an annotation that precedes neither placeholder style' do
      expect(subject.parse_annotations("INSERT INTO users (ssn) VALUES (/*@encrypt:users.ssn*/ '123')")).to eq({})
    end

    # Rule 2 - the annotation must precede the placeholder; one placed after it is not associated.
    it 'does not associate an annotation that follows the placeholder' do
      expect(subject.parse_annotations('INSERT INTO t (a) VALUES (? /*@encrypt:t.a*/)')).to eq({})
    end

    # Rule 4 - the opening delimiter must be exactly "/*@encrypt:"; a space after "/*" invalidates it.
    it 'does not match when there is a space after the opening comment delimiter' do
      expect(subject.parse_annotations('INSERT INTO t (a) VALUES (/* @encrypt:t.a*/ ?)')).to eq({})
    end

    # Rule 3 - the "table.column" grammar (regex [\w.]+) is not validated here; a bare column with no
    # table still parses. Whether "table.column" is well-formed is enforced downstream, not by the parser.
    it 'parses an annotation with a missing table part as-is' do
      expect(subject.parse_annotations('INSERT INTO t (ssn) VALUES (/*@encrypt:ssn*/ ?)')).to eq({ 1 => 'ssn' })
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

    it 'removes an annotation and preserves the numbered placeholder' do
      sql = 'INSERT INTO users (name, ssn) VALUES ($1, /*@encrypt:users.ssn*/ $2)'
      expect(subject.strip_annotations(sql)).to eq('INSERT INTO users (name, ssn) VALUES ($1, $2)')
    end

    # The strip pattern does not require a following placeholder, so a misplaced annotation that
    # parse_annotations would ignore is still removed from the SQL.
    it 'strips a misplaced annotation that is not followed by a placeholder' do
      sql = 'INSERT INTO t (a) VALUES (? /*@encrypt:t.a*/)'
      expect(subject.strip_annotations(sql)).to eq('INSERT INTO t (a) VALUES (? )')
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

    it 'returns true when an annotation is on a numbered placeholder' do
      expect(subject.annotations?('INSERT INTO users (ssn) VALUES (/*@encrypt:users.ssn*/ $1)')).to be true
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
