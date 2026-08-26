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

require 'aws_advanced_ruby_driver_wrapper/utils/sql_method_analyzer'
require 'aws_advanced_ruby_driver_wrapper/ruby_method'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::SqlMethodAnalyzer do
  let(:analyzer) { described_class }
  EXEC   = AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_EXEC.name
  QUERY  = AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_QUERY.name
  CLOSE  = AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_CLOSE.name
  TXN    = AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_TRANSACTION.name

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
    ['block comment before BEGIN',     EXEC,  ['/* hint */ BEGIN'],               true,  true],

    # Line comments on their own line — database honors the statement that follows
    ['-- COMMENT\nBEGIN',                              EXEC, ["-- COMMENT\nBEGIN"],              true,  true],
    ['--COMMENT\nSTART TRANSACTION',                   EXEC, ["--COMMENT\nSTART TRANSACTION;"],  true,  true],
    ['-- COMMENT\r\nbegin (CRLF)',                     EXEC, ["-- COMMENT\r\nbegin"],            true,  true],
    ['# COMMENT\nbegin (MySQL hash)',                  EXEC, ["# COMMENT\nbegin"],               true,  true],
    ['/*COMMENT*/ -- COMMENT\n begin',                 EXEC, ["/*COMMENT*/ -- COMMENT\n begin"], true,  true],
    ['BEGIN -- trailing line comment',                 EXEC, ['BEGIN -- COMMENT'], true, true],
    ['-- COMMENT; MORE\nBEGIN (semicolon in comment)', EXEC, ["-- COMMENT; MORE\nBEGIN"], true, true],

    # Keyword on same line as line comment stays commented out
    ['-- COMMENT BEGIN (keyword hidden)',               EXEC, ['-- COMMENT BEGIN'],               true,  false],
    ['-- BEGIN\nSELECT 1 (BEGIN hidden)',               EXEC, ["-- BEGIN\nSELECT 1"],             true,  false],

    # Line comment must not hide SET/SHOW/USE exemption in opens_transaction_scope?
    ['-- COMMENT\nset autocommit = 1 (not DML)',        EXEC, ["-- COMMENT\nset autocommit = 1"], false, false],
    ['-- COMMENT\nSHOW TABLES (not DML)',               EXEC, ["-- COMMENT\nSHOW TABLES"],        false, false],
    ['-- COMMENT\nSELECT 1 (DML, autocommit off)',      EXEC, ["-- COMMENT\nSELECT 1"],           false, true],

    # String literal containing comment marker must not be treated as a comment
    ["INSERT with '--' in string value",                EXEC, ["INSERT INTO test_table VALUES ('-- 1')"], false, true]
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
    ['INSERT',                    EXEC,  ['INSERT INTO t VALUES (1)'], false],

    # Line comments on their own line — database honors the statement that follows
    ['-- COMMENT\ncommit',                              EXEC, ["-- COMMENT\ncommit;"], true],
    ['--COMMENT\nROLLBACK',                             EXEC, ["--COMMENT\nROLLBACK"],             true],
    ['-- COMMENT\r\nend (CRLF)',                        EXEC, ["-- COMMENT\r\nend"],               true],
    ['# COMMENT\nabort (MySQL hash)',                   EXEC, ["# COMMENT\nabort"],                true],
    ['/*COMMENT*/ -- COMMENT\n commit',                 EXEC, ["/*COMMENT*/ -- COMMENT\n commit"], true],
    ['-- COMMENT; MORE\nCOMMIT (semicolon in comment)', EXEC, ["-- COMMENT; MORE\nCOMMIT"],        true],

    # Keyword on same line as line comment stays commented out
    ['-- COMMENT COMMIT (keyword hidden)',               EXEC, ['-- COMMENT COMMIT'],               false],
    ['-- COMMIT\nSELECT 1 (COMMIT hidden)',              EXEC, ["-- COMMIT\nSELECT 1"],             false]
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
    ['SET AUTOCOMMIT = TRUE',                     EXEC, ['SET AUTOCOMMIT = TRUE'],           true],
    ['SET AUTOCOMMIT = FALSE',                    EXEC, ['SET AUTOCOMMIT = FALSE'],          true],
    ['case-insensitive',                          EXEC, ['set autocommit = true'],           true],
    ['other SET statement',                       EXEC, ['SET timezone = UTC'],              false],
    ['DML',                                       EXEC, ['SELECT 1'],                        false],
    ['-- COMMENT\nset autocommit = 1',            EXEC, ["-- COMMENT\nset autocommit = 1"], true],
    ['-- COMMENT set autocommit = 1 (hidden)',    EXEC, ['-- COMMENT set autocommit = 1'], false]
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
    ['TRUE',                                ['SET AUTOCOMMIT = TRUE'],              true],
    ['1',                                   ['SET AUTOCOMMIT = 1'],                 true],
    ['ON',                                  ['SET AUTOCOMMIT = ON'],                true],
    ['FALSE',                               ['SET AUTOCOMMIT = FALSE'],             false],
    ['0',                                   ['SET AUTOCOMMIT = 0'],                 false],
    ['OFF',                                 ['SET AUTOCOMMIT = OFF'],               false],
    ['TO syntax',                           ['SET AUTOCOMMIT TO TRUE'],             true],
    ['trailing semicolon',                  ['SET AUTOCOMMIT = TRUE;'],             true],
    ['unrecognized value',                  ['SET AUTOCOMMIT = MAYBE'],             nil],
    ['non-autocommit SQL',                  ['SELECT 1'],                           nil],
    ['nil arg',                             [nil],                                  nil],
    ['-- COMMENT\nSET AUTOCOMMIT = 1',      ["-- COMMENT\nSET AUTOCOMMIT = 1 -- COMMENT"], true],
    ['SET AUTOCOMMIT = 0 # COMMENT',        ['SET AUTOCOMMIT = 0 # COMMENT'], false]
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
    ['uppercases SQL',                        'select 1',                        'SELECT 1'],
    ['strips block comments',                 '/* comment */ SELECT 1',          'SELECT 1'],
    ['takes first before ;',                  'BEGIN; INSERT INTO t VALUES (1)', 'BEGIN'],
    ['nil',                                   nil,                               nil],
    ['empty string',                          '',                                nil],
    ['whitespace only',                       '   ',                             nil],
    ['non-string',                            123,                               nil],
    ['strips -- line comment',                 "-- note\nBEGIN",          'BEGIN'],
    ['strips # line comment',                  "# note\nBEGIN",           'BEGIN'],
    ['-- comment with ; does not split early', "-- COMMENT; MORE\nCOMMIT", 'COMMIT'],
    ['quoted string preserves -- inside',      "SELECT '--' AS x",         "SELECT '--' AS X"]
  ].freeze

  describe '.first_statement' do
    FIRST_STATEMENT_CASES.each do |desc, input, expected|
      it "#{desc} → #{expected.inspect}" do
        expect(analyzer.first_statement(input)).to eq(expected)
      end
    end
  end

  # ─── strip_comments edge cases ───────────────────────────────────────
  describe '.strip_comments' do
    context 'Postgres dollar-quoted strings' do
      it 'preserves comment markers inside $$...$$' do
        expect(analyzer.strip_comments('DO $$ BEGIN -- x $$ SELECT 1')).to include('-- x')
      end

      it 'preserves comment markers inside named $tag$...$tag$' do
        expect(analyzer.strip_comments('SELECT $body$ /* not a comment */ $body$')).to include('/* not a comment */')
      end

      it 'strips a real comment after a dollar-quoted string' do
        result = analyzer.strip_comments("SELECT $$ hi $$ -- comment\nFROM t")
        expect(result).not_to include('-- comment')
        expect(result).to include('$$ hi $$')
      end

      it 'does not treat $1 positional parameters as dollar-quote tags' do
        result = analyzer.strip_comments('SELECT $1, $2 -- comment')
        expect(result).to include('$1, $2')
        expect(result).not_to include('-- comment')
      end

      it 'does not treat $1 in WHERE clause as dollar-quote tag' do
        result = analyzer.strip_comments('SELECT id FROM users WHERE id = $1 -- filter by id')
        expect(result).to include('$1')
        expect(result).not_to include('-- filter by id')
      end

      it 'does not treat $1 in INSERT as dollar-quote tag' do
        result = analyzer.strip_comments('INSERT INTO orders (user_id, total) VALUES ($1, $2) /* tracking comment */')
        expect(result).to include('$1, $2')
        expect(result).not_to include('/* tracking comment */')
      end
    end

    context 'MySQL backslash escapes' do
      it "does not end quote early on \\' when backslash_escapes: true" do
        sql = "SELECT 'it\\'s -- x' FROM t"
        result = analyzer.strip_comments(sql, mysql_backslash_escapes: true)
        expect(result).to include("'it\\'s -- x'")
      end

      it 'ends quote at doubled quote when backslash_escapes: false (default)' do
        # 'it''s -- x' is a valid doubled-quote escape; comment after closing quote is stripped
        sql = "SELECT 'it''s' -- comment\nFROM t"
        result = analyzer.strip_comments(sql)
        expect(result).not_to include('-- comment')
        expect(result).to include("'it''s'")
      end
    end

    context 'Postgres nested block comments' do
      it 'handles /* outer /* inner */ still outer */' do
        result = analyzer.strip_comments('/* outer /* inner */ still outer */ BEGIN')
        expect(result.strip).to eq('BEGIN')
      end

      it 'does not leak the closing */ of an inner comment' do
        result = analyzer.strip_comments('SELECT /* a /* b */ */ 1')
        expect(result).not_to include('*/')
        expect(result.gsub(/\s+/, ' ').strip).to eq('SELECT 1')
      end

      it 'handles unterminated nested comment at end of string without leaking' do
        result = analyzer.strip_comments('SELECT 1 /* unclosed')
        expect(result).not_to include('/*')
        expect(result.strip).to eq('SELECT 1')
      end

      it 'handles well-formed comment closing exactly at end of string' do
        result = analyzer.strip_comments('SELECT id FROM accounts /*audit*/')
        expect(result).not_to include('/*')
        expect(result).not_to include('*/')
        expect(result.strip).to eq('SELECT id FROM accounts')
      end

      it 'handles nested comment closing exactly at end of string' do
        result = analyzer.strip_comments('UPDATE sessions SET active = false /* cleanup /* stale */ */')
        expect(result).not_to include('/*')
        expect(result).not_to include('*/')
        expect(result.strip).to eq('UPDATE sessions SET active = false')
      end
    end

    context 'mysql_backslash_escapes threading through public API' do
      it 'opens_transaction? respects backslash escape flag' do
        # Without the flag, 'it\'s -- x' ends the literal at the backslash-quote,
        # making the rest look like a comment; with the flag the literal is preserved
        # and the INSERT is still seen as opening a transaction.
        sql = "INSERT INTO t VALUES ('it\\'s value')"
        expect(analyzer.opens_transaction?(EXEC, [sql], autocommit: false, mysql_backslash_escapes: true)).to eq(true)
      end

      it 'closes_transaction? is not fooled by backslash-escaped quote hiding COMMIT' do
        # 'don\'t COMMIT yet' — without the flag the literal ends at \', leaving
        # COMMIT yet' as bare SQL which would be misread as a COMMIT statement.
        sql = "INSERT INTO audit_log (note) VALUES ('don\\'t COMMIT yet')"
        expect(analyzer.closes_transaction?(EXEC, [sql], mysql_backslash_escapes: true)).to eq(false)
      end

      it 'sets_autocommit? is not fooled by backslash-escaped quote hiding SET AUTOCOMMIT' do
        sql = "INSERT INTO settings (val) VALUES ('don\\'t SET AUTOCOMMIT = 0')"
        expect(analyzer.sets_autocommit?(EXEC, [sql], mysql_backslash_escapes: true)).to eq(false)
      end
    end
  end
end
