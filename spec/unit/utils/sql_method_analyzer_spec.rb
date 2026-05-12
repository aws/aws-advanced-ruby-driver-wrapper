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

require 'aws_ruby_database_driver_wrapper/utils/sql_method_analyzer'
require 'aws_ruby_database_driver_wrapper/ruby_method'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::SqlMethodAnalyzer do
  let(:analyzer) { described_class }

  EXEC   = AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_EXEC
  QUERY  = AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_QUERY
  CLOSE  = AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_CLOSE
  TXN    = AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_TRANSACTION
  PING   = 'connection.ping'

  # ─── opens_transaction? ──────────────────────────────────────────────
  #   [description, method, args, autocommit, expected]
  OPENS_TRANSACTION_CASES = [
    # Explicit transaction start
    ['BEGIN',                          EXEC,  ['BEGIN'],                          true,  true],
    ['begin (case-insensitive)',       EXEC,  ['begin'],                          true,  true],
    ['START TRANSACTION',              EXEC,  ['START TRANSACTION'],              true,  true],
    ['BEGIN via query method',         QUERY, ['BEGIN'],                          true,  true],

    # DML with autocommit OFF (implicit transaction)
    ['INSERT with autocommit off',    EXEC,  ['INSERT INTO t VALUES (1)'],       false, true],
    ['SELECT with autocommit off',    EXEC,  ['SELECT * FROM t'],                false, true],
    ['UPDATE with autocommit off',    EXEC,  ['UPDATE t SET x = 1'],             false, true],
    ['DELETE with autocommit off',    EXEC,  ['DELETE FROM t'], false, true],

    # DML with autocommit ON (no implicit transaction)
    ['INSERT with autocommit on',     EXEC,  ['INSERT INTO t VALUES (1)'],       true,  false],
    ['SELECT with autocommit on',     EXEC,  ['SELECT * FROM t'],                true,  false],

    # Non-DML statements (never open transactions even with autocommit off)
    ['SET with autocommit off',       EXEC,  ['SET timezone = UTC'],             false, false],
    ['USE with autocommit off',       EXEC,  ['USE mydb'],                       false, false],
    ['SHOW with autocommit off',      EXEC,  ['SHOW tables'],                    false, false],

    # Edge cases
    ['nil args',                       EXEC,  nil,                                true,  false],
    ['empty string',                   EXEC,  [''],                               true,  false],
    ['non-string arg',                 EXEC,  [123],                              true,  false],
    ['multi-statement (first wins)',   EXEC,  ['BEGIN; INSERT INTO t VALUES(1)'], true,  true],
    ['block comment before BEGIN',     EXEC,  ['/* hint */ BEGIN'],               true,  true]
  ].freeze

  describe '.opens_transaction?' do
    OPENS_TRANSACTION_CASES.each do |desc, method, args, autocommit, expected|
      it "#{desc} → #{expected}" do
        expect(analyzer.opens_transaction?(method, args, autocommit: autocommit)).to eq(expected)
      end
    end
  end

  # ─── closes_transaction? ─────────────────────────────────────────────
  #   [description, method, args, expected]
  CLOSES_TRANSACTION_CASES = [
    ['COMMIT',                    EXEC,  ['COMMIT'],   true],
    ['ROLLBACK',                  EXEC,  ['ROLLBACK'], true],
    ['END',                       EXEC,  ['END'],      true],
    ['ABORT',                     EXEC,  ['ABORT'],    true],
    ['commit (case-insensitive)', EXEC,  ['commit'],   true],
    ['connection.close method',   CLOSE, [],           true],
    ['connection.transaction',    TXN,   [],           true],
    ['DML does not close',        EXEC,  ['SELECT 1'], false],
    ['non-execute method',        PING,  ['COMMIT'],   false],
    ['INSERT',                    EXEC,  ['INSERT INTO t VALUES (1)'], false]
  ].freeze

  describe '.closes_transaction?' do
    CLOSES_TRANSACTION_CASES.each do |desc, method, args, expected|
      it "#{desc} → #{expected}" do
        expect(analyzer.closes_transaction?(method, args)).to eq(expected)
      end
    end
  end

  # ─── sets_autocommit? ────────────────────────────────────────────────
  #   [description, method, args, expected]
  SETS_AUTOCOMMIT_CASES = [
    ['SET AUTOCOMMIT = TRUE',         EXEC,  ['SET AUTOCOMMIT = TRUE'],  true],
    ['SET AUTOCOMMIT = FALSE',        EXEC,  ['SET AUTOCOMMIT = FALSE'], true],
    ['case-insensitive',              EXEC,  ['set autocommit = true'],  true],
    ['other SET statement',           EXEC,  ['SET timezone = UTC'],     false],
    ['non-execute method',            PING,  ['SET AUTOCOMMIT = TRUE'],  false],
    ['DML',                           EXEC,  ['SELECT 1'],               false]
  ].freeze

  describe '.sets_autocommit?' do
    SETS_AUTOCOMMIT_CASES.each do |desc, method, args, expected|
      it "#{desc} → #{expected}" do
        expect(analyzer.sets_autocommit?(method, args)).to eq(expected)
      end
    end
  end

  # ─── autocommit_value ────────────────────────────────────────────────
  #   [description, args, expected]
  AUTOCOMMIT_VALUE_CASES = [
    ['TRUE',                  ['SET AUTOCOMMIT = TRUE'],  true],
    ['1',                     ['SET AUTOCOMMIT = 1'],     true],
    ['ON',                    ['SET AUTOCOMMIT = ON'],    true],
    ['FALSE',                 ['SET AUTOCOMMIT = FALSE'], false],
    ['0',                     ['SET AUTOCOMMIT = 0'],     false],
    ['OFF',                   ['SET AUTOCOMMIT = OFF'],   false],
    ['TO syntax',             ['SET AUTOCOMMIT TO TRUE'], true],
    ['trailing semicolon',    ['SET AUTOCOMMIT = TRUE;'], true],
    ['unrecognized value',    ['SET AUTOCOMMIT = MAYBE'], nil],
    ['non-autocommit SQL',    ['SELECT 1'],               nil],
    ['nil arg',               [nil],                      nil]
  ].freeze

  describe '.autocommit_value' do
    AUTOCOMMIT_VALUE_CASES.each do |desc, args, expected|
      it "#{desc} → #{expected.inspect}" do
        expect(analyzer.autocommit_value(args)).to eq(expected)
      end
    end
  end

  # ─── first_statement ─────────────────────────────────────────────────
  #   [description, input, expected]
  FIRST_STATEMENT_CASES = [
    ['uppercases SQL',            'select 1',                        'SELECT 1'],
    ['strips block comments',     '/* comment */ SELECT 1',          'SELECT 1'],
    ['takes first before ;',      'BEGIN; INSERT INTO t VALUES (1)', 'BEGIN'],
    ['nil',                       nil,                               nil],
    ['empty string',              '',                                nil],
    ['whitespace only',           '   ',                             nil],
    ['non-string',                123,                               nil]
  ].freeze

  describe '.first_statement' do
    FIRST_STATEMENT_CASES.each do |desc, input, expected|
      it "#{desc} → #{expected.inspect}" do
        expect(analyzer.first_statement(input)).to eq(expected)
      end
    end
  end
end
