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

require 'concurrent'
require_relative '../../logging'
require_relative '../../ruby_method'
require_relative '../../utils/parser/encryption_annotation_parser'
require_relative '../../utils/parser/query_type'
require_relative '../../utils/parser/sql_parser'
require_relative '../../utils/sql_encoding'
require_relative 'column_cipher'
require_relative 'errors'
require_relative 'kms_encryption_utility'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    # Encrypts and decrypts individual table columns with keys held in AWS KMS, without the
    # application having to know about it.
    #
    # Which columns are encrypted is configured in the database rather than in application code, so
    # it can change without redeploying the application. That configuration is managed through
    # {Encryption::KeyManagementUtility} rather than by editing the tables by hand. When a
    # statement writes to one of those columns the plugin encrypts the bind parameter on its way to
    # the server, and when a statement reads one back it decrypts the value on its way to the
    # application. The plaintext never reaches the server, and the data keys never reach it either:
    # only a KMS encrypted copy of each data key is stored, in +key_storage+.
    #
    # Encryption applies to bind parameters, so a value can only be encrypted when it is bound
    # rather than written into the SQL text:
    #
    #   # pg
    #   conn.exec_params('INSERT INTO users (name, ssn) VALUES ($1, $2)', ['Jo', '123-45-6789'])
    #   conn.exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).each { |row| row['ssn'] }
    #
    #   # mysql2
    #   client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)').execute('Jo', '123-45-6789')
    #
    # The plugin works out which parameter belongs to which column by parsing the statement. When
    # the statement is too involved for that, the column can be named explicitly with an
    # annotation, which takes precedence over anything the parser found:
    #
    #   conn.exec_params('INSERT INTO users (name, ssn) VALUES ($1, /*@encrypt:users.ssn*/ $2)', ...)
    #
    # Decrypted values are always returned as strings, whatever type the value had when it was
    # written. An encrypted column is a binary column (+bytea+ or +VARBINARY+), which is what both
    # drivers return as a string, so a string keeps the read consistent with the column's real type
    # and with how ActiveRecord treats it. Cast the value on read when the application needs another
    # type, for example +row['age'].to_i+.
    #
    # A row is decrypted however it is read. A row read as a hash is matched to its columns by name;
    # a row (or single cell) read as bare values is matched by position, through the field list the
    # result reports, which is what lets ActiveRecord's reads decrypt even though it fetches rows as
    # arrays. This covers +PG::Result+'s +#each+, +#each_row+, +#to_a+, +#[]+, +#values+,
    # +#field_values+, +#column_values+, +#tuple+, +#tuple_values+ and +#getvalue+, its single-row
    # streaming +#stream_each+ / +#stream_each_row+ / +#stream_each_tuple+, and mysql2's hash and
    # array results alike. A +COPY ... TO+ is the exception: its rows are a stream rather than values
    # the plugin can replace, so it hands out what the column holds.
    #
    # The plugin does not try to guarantee that an encrypted column never holds a plaintext - it
    # cannot, since it only sees the statements this wrapper sends over a connection that has it
    # enabled, and only the ones it can read that far. That guarantee is the database's to make, with
    # a trigger that checks a value's integrity tag as it goes in (it can do so without the data key,
    # because the HMAC key is stored in +key_storage+), and installing one is required; see the
    # plugin docs. The plugin's job is to encrypt every value it can confidently place into an
    # encrypted column and to stay out of the way otherwise.
    #
    # So when the plugin cannot read a statement well enough to be sure - the tables it writes cannot
    # be established, or a table has encrypted columns but which of them this statement writes cannot
    # be enumerated, or a value is bound to a prepared statement whose text the connection never saw -
    # it passes the statement through rather than refusing it, and leaves a plaintext for the database
    # trigger to reject. Refusing here would reject legitimate statements that never touch an
    # encrypted column at all.
    #
    # The one write-side case it still fails closed on is the one it can be certain about: a column it
    # has confirmed is encrypted, written with something other than a bind parameter (a literal, an
    # expression, a DEFAULT, a +COPY+ stream), which cannot be encrypted. That is almost always a
    # mistake, so it is refused with advice to bind or annotate the value. An annotation naming the
    # column takes it off the plugin's hands; a +COPY+ has no parameter for one to name, so it is
    # steered to +INSERT+ instead.
    #
    # A prepared statement is run by name, so the plugin reads the statement the connection remembers
    # preparing under that name, whether it was prepared by the driver's own +prepare+ or by a
    # +PREPARE+ sent as a statement. A +PREPARE+ is also checked as it is sent, and not only when its
    # name is later run, since a value written into the statement it carries rather than left as a
    # parameter is only in hand while the +PREPARE+ itself is.
    class KmsEncryptionPlugin
      include Logging

      # Statement methods whose bind parameters may have to be encrypted, mapped to the position of
      # the parameter array in the argument list. A nil position means the arguments are themselves
      # the parameters.
      PARAMETER_METHODS = {
        RubyMethod::CONNECTION_EXEC.name => 1,
        RubyMethod::CONNECTION_ASYNC_EXEC.name => 1,
        RubyMethod::CONNECTION_EXEC_PARAMS.name => 1,
        RubyMethod::CONNECTION_SEND_QUERY.name => 1,
        RubyMethod::CONNECTION_SEND_QUERY_PARAMS.name => 1,
        RubyMethod::CONNECTION_EXEC_PREPARED.name => 1,
        RubyMethod::CONNECTION_SEND_QUERY_PREPARED.name => 1,
        RubyMethod::STATEMENT_EXECUTE.name => nil
      }.freeze

      # Statement methods that take no bind parameters. There is nothing to encrypt for these, but a
      # statement that carries its values outside its bind parameters is exactly the one that could
      # write a confirmed encrypted column unencryptably, so they are still run through the write
      # check.
      #
      # mysql2's +query+ covers its asynchronous path as well, since that is the same call with
      # +async: true+ passed to it, and the statement is inspected when it is sent either way.
      #
      # pg's +copy_data+ is here because it opens its COPY on the driver's own connection rather than
      # through the wrapper, so the statement would otherwise never be seen. Checking it when the COPY
      # is opened is what makes checking the calls that feed it unnecessary: a COPY that names a
      # confirmed encrypted column is refused before there is anywhere to put a row.
      WRITE_CHECK_METHODS = Set[
        RubyMethod::CONNECTION_QUERY.name,
        RubyMethod::CONNECTION_COPY_DATA.name
      ].freeze

      # Result methods that yield rows to a block, one at a time. The +stream_+ variants are the
      # single-row-mode iterators, which read rows off the wire one at a time but hand out the same
      # row shapes.
      ROW_BLOCK_METHODS = Set[
        RubyMethod::RESULT_EACH.name,
        RubyMethod::RESULT_EACH_ROW.name,
        RubyMethod::RESULT_STREAM_EACH.name,
        RubyMethod::RESULT_STREAM_EACH_ROW.name,
        RubyMethod::RESULT_STREAM_EACH_TUPLE.name
      ].freeze

      # Result methods that return every row at once, as an array of rows.
      ROW_COLLECTION_METHODS = Set[
        RubyMethod::RESULT_TO_A.name,
        RubyMethod::RESULT_VALUES.name
      ].freeze

      # Result methods that return a single row.
      ROW_SINGLE_METHODS = Set[
        RubyMethod::RESULT_BRACKET.name,
        RubyMethod::RESULT_TUPLE.name,
        RubyMethod::RESULT_TUPLE_VALUES.name
      ].freeze

      # Every result method that hands out whole rows, however it does so. A row may arrive as a hash
      # keyed by column name or as an array of bare values, and either is decrypted: a hash by name,
      # an array by matching each position to a column through the result's field list.
      ROW_METHODS = (ROW_BLOCK_METHODS + ROW_COLLECTION_METHODS + ROW_SINGLE_METHODS).freeze

      # Result methods that hand out every value of one column. One names the column; the other gives
      # its position in the result, which is matched to a name through the field list.
      COLUMN_BY_NAME_METHOD = RubyMethod::RESULT_FIELD_VALUES.name
      COLUMN_BY_INDEX_METHOD = RubyMethod::RESULT_COLUMN_VALUES.name

      # The result method that hands out a single cell by row and column position.
      VALUE_BY_INDEX_METHOD = RubyMethod::RESULT_GETVALUE.name

      # Statement types that store values. These are the ones run through the write check, which
      # refuses a statement that writes a confirmed encrypted column with a value it cannot encrypt
      # and otherwise leaves the statement to the database's own enforcement.
      WRITE_QUERY_TYPES = Set[
        Utils::Parser::QueryType::INSERT,
        Utils::Parser::QueryType::UPDATE,
        Utils::Parser::QueryType::COPY
      ].freeze

      # A statement that stores values, as far as its keywords go. The keywords are looked at as well
      # as the parse, because a statement the parser could not read has no query type, and that is
      # precisely the case that must not be mistaken for a read.
      #
      # The keyword is not always the first thing in the text. Query instrumentation prepends a
      # comment routinely, and a common table expression can come in front of a statement that
      # writes, so both are stepped over before the keyword is looked for.
      WRITE_KEYWORDS = %r{
        \A(?:\s|\(|/\*.*?\*/|--[^\n]*|\#[^\n]*)*   # comments and whitespace in front of it
        (?:WITH\s.*?\s)?                           # a common table expression in front of it
        (?:INSERT|UPDATE|REPLACE|UPSERT|MERGE)\b
      }imx

      # What a character is replaced with in the copy of the SQL the plugin reads when the SQL's
      # encoding has no UTF-8 form for it (see {Utils::SqlEncoding.inspectable}).
      UNREADABLE_CHARACTER = "\uFFFD"

      SUBSCRIBED_METHODS = (
        Set[RubyMethod::CONNECTION_CLOSE.name, COLUMN_BY_NAME_METHOD, COLUMN_BY_INDEX_METHOD, VALUE_BY_INDEX_METHOD] +
          PARAMETER_METHODS.keys + WRITE_CHECK_METHODS + ROW_METHODS
      ).freeze

      attr_reader :subscribed_methods, :encryption_utility

      # @param service_container [Services::ServiceContainer]
      # @param props [Concurrent::Map, Hash] the wrapper properties
      # @param encryption_utility [Encryption::KmsEncryptionUtility, nil] a utility to use instead
      #   of building one
      def initialize(service_container, props = ::Concurrent::Map.new, encryption_utility: nil)
        @service_container = service_container
        @encryption_utility = encryption_utility || Encryption::KmsEncryptionUtility.new(service_container, props)
        # Built up front so that a parser dependency the application has not installed (pg_query, on
        # PostgreSQL) fails the connection as it is set up rather than its first statement.
        @sql_parser = Utils::Parser::SqlParser.new(service_container.dialect_service.driver_dialect)
        @subscribed_methods = SUBSCRIBED_METHODS
        # The names already warned about by {#unreadable_name?}, which is asked on every lookup and so
        # would otherwise repeat the same warning for every row and statement that touches the name.
        @unreadable_names = ::Concurrent::Set.new
      end

      # The call's block is taken from the call context rather than from a block parameter, since
      # that is where the pipeline reads the block it passes on.
      def execute(method_name, pipeline_callable, *args, **_kwargs)
        return close_connection(pipeline_callable) if method_name == RubyMethod::CONNECTION_CLOSE.name

        context = @service_container.plugin_manager.current_call_context
        sql = context&.sql

        if PARAMETER_METHODS.key?(method_name)
          encrypt_parameters(method_name, args, context, sql)
          pipeline_callable.call
        elsif WRITE_CHECK_METHODS.include?(method_name)
          verify_statement(sql)
          pipeline_callable.call
        elsif ROW_METHODS.include?(method_name)
          read_rows(method_name, pipeline_callable, context, sql)
        elsif method_name == COLUMN_BY_NAME_METHOD
          read_named_column(pipeline_callable, args.first, sql)
        elsif method_name == COLUMN_BY_INDEX_METHOD
          read_indexed_column(pipeline_callable, args.first, context, sql)
        elsif method_name == VALUE_BY_INDEX_METHOD
          read_indexed_value(pipeline_callable, args, context, sql)
        else
          pipeline_callable.call
        end
      end

      private

      def close_connection(pipeline_callable)
        @encryption_utility.cleanup
        pipeline_callable.call
      end

      # -- Writing --

      # Replaces every bind parameter that belongs to an encrypted column with its encrypted form.
      # The parameters are handed back through the call context, so that the application's own
      # array is left as it was.
      def encrypt_parameters(method_name, args, context, sql)
        return if context.nil?

        position = PARAMETER_METHODS[method_name]
        parameters = position.nil? ? args : args[position]
        parameters = [] unless parameters.is_a?(Array)
        return note_unknown_statement(parameters) if sql.nil?

        # Asked for even when there is nothing to bind, since that is what says whether the
        # statement is storing a value the plugin cannot reach.
        columns = parameter_columns(sql)
        return if columns.empty? || parameters.empty?

        encrypted = encrypt_each(parameters, columns)
        return if encrypted.nil?

        if position.nil?
          context.args = encrypted
        else
          rewritten = args.dup
          rewritten[position] = encrypted
          context.args = rewritten
        end
      end

      # A call whose statement the wrapper never saw: a prepared statement run by name after something
      # other than a +prepare+ or a +PREPARE+ brought it into being (one prepared inside a
      # multi-statement string, on the driver's connection directly, or by a client library of its
      # own devising). The plugin cannot tell which column each bound value fills, so it leaves them
      # to the database rather than refusing the call; if any targets an encrypted column, the
      # required server-side enforcement is what catches a plaintext bound this way. Logged at debug
      # since the great majority of such statements touch no encrypted column at all.
      def note_unknown_statement(parameters)
        return if parameters.empty?

        logger.debug { 'The kms_encryption plugin is binding values to a statement it never saw; leaving them to the database' }
      end

      # A statement with no bind parameters has nothing to encrypt, so only its safety is at stake.
      def verify_statement(sql)
        return if sql.nil?

        parameter_columns(sql) # nothing to bind; called for the checks it makes
      end

      # @return [Array, nil] the parameters with the encrypted ones replaced, nil when none were
      def encrypt_each(parameters, columns)
        cipher = new_cipher
        encrypted = nil

        begin
          parameters.each_with_index do |parameter, index|
            config = columns[index + 1]
            value = parameter_value(parameter)
            next if config.nil? || value.nil?

            encrypted ||= parameters.dup
            encrypted[index] = bind_value(encrypt_value(value, config, cipher))
          end
        ensure
          cipher.release
        end

        encrypted
      end

      # pg also takes a parameter as a hash that carries its value along with its format and type, and
      # ActiveRecord binds every binary column that way. Only the value is encrypted: the ciphertext
      # is bound as binary whatever format the hash named, and a hash with no value stays null.
      def parameter_value(parameter)
        parameter.is_a?(Hash) && sql_runner.pg? ? parameter[:value] : parameter
      end

      def encrypt_value(value, config, cipher)
        cipher.encrypt(value, config)
      rescue StandardError => e
        audit_logger.log_encryption(
          table_name: config.table_name, column_name: config.column_name, key_id: config.key_id,
          success: false, error_message: e.message
        )
        raise
      end

      # An encrypted value is binary, and neither driver would send a Ruby string as binary on its
      # own: pg needs to be told the parameter format, and mysql2 needs the encoding.
      def bind_value(encrypted)
        sql_runner.binary_param(encrypted)
      end

      # -- Reading --

      def read_rows(method_name, pipeline_callable, context, sql)
        columns = column_configs(sql)
        return pipeline_callable.call if columns.empty?

        cipher = new_cipher
        field_names = context&.field_names
        columns = keyed_by_field_names(columns, field_names)
        # A row read as an array of values is matched to its columns by position; a row read as a
        # hash is matched by name and never needs this. It is worked out once for the whole result.
        positions = encrypted_positions(columns, field_names)
        caller_block = context&.block

        begin
          if ROW_BLOCK_METHODS.include?(method_name) && caller_block
            # each and each_row yield the rows rather than returning them, so the block is what has
            # to be decrypted through. Replacing it in the call context leaves the caller's own block
            # untouched. A lambda is used rather than a proc so that a row yielded as an array of
            # values is passed on whole, instead of being splatted across the block's parameters.
            context.block = ->(row, *rest) { caller_block.call(decrypt_row(row, columns, positions, cipher), *rest) }
            pipeline_callable.call
          elsif ROW_BLOCK_METHODS.include?(method_name)
            # Called without a block, each and each_row return an Enumerator over the rows. The rows
            # are decrypted eagerly and handed back as an enumerator over the results, because the
            # cipher is released as soon as this method returns and a lazy wrapper would decrypt with
            # a spent cipher.
            result = pipeline_callable.call
            result.respond_to?(:map) ? result.map { |row| decrypt_row(row, columns, positions, cipher) }.each : result
          elsif ROW_COLLECTION_METHODS.include?(method_name)
            rows = pipeline_callable.call
            rows.is_a?(Array) ? rows.map { |row| decrypt_row(row, columns, positions, cipher) } : rows
          else
            decrypt_row(pipeline_callable.call, columns, positions, cipher)
          end
        ensure
          cipher.release
        end
      end

      # field_values hands back one named column's values, so the column is looked up by name.
      def read_named_column(pipeline_callable, field_name, sql)
        config = field_name.nil? ? nil : config_named(column_configs(sql), field_name)
        decrypt_column(pipeline_callable, config)
      end

      # column_values hands back one column's values by position, so the position is matched to a
      # column name through the result's field list before the values are decrypted.
      def read_indexed_column(pipeline_callable, index, context, sql)
        columns = column_configs(sql)
        config = columns.empty? ? nil : column_at(index, context&.field_names, columns)
        decrypt_column(pipeline_callable, config)
      end

      # getvalue hands back a single cell by row and column position (+args+ is +[row, column]+), so
      # the column position is matched to a name through the field list before the value is decrypted.
      def read_indexed_value(pipeline_callable, args, context, sql)
        columns = column_configs(sql)
        config = columns.empty? ? nil : column_at(args[1], context&.field_names, columns)
        return pipeline_callable.call if config.nil?

        cipher = new_cipher

        begin
          decrypt_value(pipeline_callable.call, config, cipher)
        ensure
          cipher.release
        end
      end

      def decrypt_column(pipeline_callable, config)
        return pipeline_callable.call if config.nil?

        cipher = new_cipher

        begin
          values = pipeline_callable.call
          values.is_a?(Array) ? values.map { |value| decrypt_value(value, config, cipher) } : values
        ensure
          cipher.release
        end
      end

      # @param columns [Hash{String => ColumnEncryptionConfig}] the encrypted columns of the
      #   statement, by name, for a row read as a hash
      # @param positions [Array<Array(Integer, ColumnEncryptionConfig)>] the encrypted columns by
      #   position, for a row read as an array of values
      # @return [Object] the row, with a new hash or array substituted only when something was
      #   decrypted
      def decrypt_row(row, columns, positions, cipher)
        case row
        when Hash then decrypt_named_row(row, columns, cipher)
        when Array then decrypt_indexed_row(row, positions, cipher)
        else pg_tuple?(row) ? decrypt_tuple(row, columns, cipher) : row
        end
      end

      # A row read as a hash: the encrypted columns are found by name.
      def decrypt_named_row(row, columns, cipher)
        decrypted = nil
        columns.each do |column_name, config|
          next unless row.key?(column_name)

          raw = row[column_name]
          value = decrypt_value(raw, config, cipher)
          next if value.equal?(raw)

          decrypted ||= row.dup
          decrypted[column_name] = value
        end

        decrypted || row
      end

      # A row read as an array of values: the encrypted columns are found by position.
      def decrypt_indexed_row(row, positions, cipher)
        decrypted = nil
        positions.each do |index, config|
          raw = row[index]
          value = decrypt_value(raw, config, cipher)
          next if value.equal?(raw)

          decrypted ||= row.dup
          decrypted[index] = value
        end

        decrypted || row
      end

      # A pg tuple is read-only and keyed by column name, so a decrypted copy is handed back as a
      # plain hash, and only when a column was actually decrypted so an unaffected tuple keeps its
      # type.
      def decrypt_tuple(row, columns, cipher)
        keys = row.keys
        copy = nil
        columns.each do |column_name, config|
          next unless keys.include?(column_name)

          raw = row[column_name]
          value = decrypt_value(raw, config, cipher)
          next if value.equal?(raw)

          copy ||= keys.zip(row.values).to_h
          copy[column_name] = value
        end

        copy || row
      end

      # Matches each encrypted column to its position in a result read as arrays of values, so a row
      # can be decrypted by index. Empty when the call carried no field list (a row read as a hash
      # never needs it) or none of the result's columns is encrypted.
      #
      # @param columns [Hash{String => ColumnEncryptionConfig}] encrypted columns by name
      # @param field_names [Array<String>, nil] the result's columns in order
      # @return [Array<Array(Integer, ColumnEncryptionConfig)>]
      def encrypted_positions(columns, field_names)
        return [] if field_names.nil? || columns.empty?

        field_names.each_with_index.with_object([]) do |(name, index), positions|
          config = columns[name.to_s]
          positions << [index, config] if config
        end
      end

      # @return [ColumnEncryptionConfig, nil] the encrypted column at a position in the result, nil
      #   when the position is out of range or the column there is not encrypted
      def column_at(index, field_names, columns)
        return nil unless index.is_a?(Integer) && field_names

        name = field_names[index]
        name.nil? ? nil : config_named(columns, name)
      end

      # A result names its columns in the connection's encoding, while the configuration names them in
      # UTF-8, so on a connection that is not UTF-8 a column whose name is not ASCII is named
      # differently by each. The columns are keyed by the names the result uses as well, once for the
      # whole result, so that each row is looked up by the name it actually carries. The columns are
      # only copied when a name differs, so a result on a UTF-8 connection gets them as they are.
      #
      # @param columns [Hash{String => ColumnEncryptionConfig}] encrypted columns by UTF-8 name
      # @param field_names [Array<String>, nil] the result's columns in order
      # @return [Hash{String => ColumnEncryptionConfig}]
      def keyed_by_field_names(columns, field_names)
        return columns if field_names.nil?

        keyed = nil
        field_names.each do |name|
          name = name.to_s
          next if columns.key?(name)

          config = columns[Utils::SqlEncoding.inspectable(name)]
          (keyed ||= columns.dup)[name] = config if config
        end
        keyed || columns
      end

      # @return [ColumnEncryptionConfig, nil] the encrypted column a result or the application names,
      #   whatever the encoding of the name
      def config_named(columns, name)
        name = name.to_s
        columns[name] || columns[Utils::SqlEncoding.inspectable(name)]
      end

      def pg_tuple?(row)
        defined?(PG::Tuple) && row.is_a?(PG::Tuple)
      end

      def decrypt_value(raw, config, cipher)
        cipher.decrypt(raw, config)
      rescue StandardError => e
        # In lenient mode a value that cannot be confirmed to be this column's encrypted data - too
        # short to be a payload, or a failed HMAC - is returned as it is stored, so a column holding
        # values written before kms_encryption was enabled still reads back. A value that verifies
        # but will not decrypt (a GCM/data-key failure) is never returned unverified: it signals a
        # real key problem, so only an integrity-check failure is eligible. Returning +raw+ is how
        # the row readers see "not decrypted, leave as-is".
        lenient = return_unverified_data? && e.is_a?(Errors::EncryptionError) &&
                  e.code == Errors::EncryptionError::INTEGRITY_CHECK_FAILED
        audit_logger.log_decryption(
          table_name: config.table_name, column_name: config.column_name, key_id: config.key_id,
          success: false, error_message: lenient ? "returned unverified: #{e.message}" : e.message
        )
        return raw if lenient

        raise
      end

      # @return [Boolean] whether a value that cannot be verified on read is returned as it is stored
      #   rather than raised on. Off by default; not for production - see the property's documentation.
      def return_unverified_data?
        @encryption_utility.config.return_unverified_data
      end

      # -- Statement analysis --

      # The encrypted columns a statement's bind parameters write to.
      #
      # @return [Hash{Integer => ColumnEncryptionConfig}] by 1-based parameter index
      # @raise [Errors::MetadataError] when the statement writes a column the plugin has confirmed is
      #   encrypted with a value it cannot encrypt (see {#check_write})
      def parameter_columns(sql)
        annotations = Utils::Parser::EncryptionAnnotationParser.parse_annotations(sql)
        stripped = stripped_sql(sql)
        analysis = analysis_of(stripped)
        write = write_statement?(analysis, stripped)
        inferred = analysis.parameter_column_names
        return {} if !write && annotations.empty? && inferred.empty?
        return {} unless ready_for_statement?(sql)

        tables = statement_tables(analysis, annotations)
        check_write(analysis, tables, annotations) if write

        inferred.merge(annotations).each_with_object({}) do |(index, reference), columns|
          config = resolve_column(reference, tables)
          columns[index] = config if config
        end
      end

      # The statement as far as it could be read. A parse that fails is not the same as a statement
      # that writes nothing, so it is reported as nothing having been read rather than as nothing
      # being there to read.
      #
      # @return [Utils::Parser::SqlParser::SqlAnalysisResult]
      def analysis_of(sql)
        sql_parser.analyze_sql(sql)
      rescue StandardError => e
        logger.warn("The statement could not be analysed: #{e.message}")
        Utils::Parser::SqlParser::SqlAnalysisResult.new(
          query_type: Utils::Parser::QueryType::UNKNOWN,
          affected_tables: Set.new,
          write_columns_complete: false
        )
      end

      def write_statement?(analysis, sql)
        WRITE_QUERY_TYPES.include?(analysis.query_type) || WRITE_KEYWORDS.match?(sql.to_s)
      end

      # The one write-side check the plugin fails closed on: a column it has confirmed is
      # encrypted, but that this statement writes with something other than a bind parameter (a
      # literal, an expression, a DEFAULT, a COPY stream), which cannot be encrypted. That is almost
      # always a mistake, and storing a plaintext in an encrypted column reads back clean ever after,
      # so it is refused with advice to bind or annotate the value. An annotation naming the column
      # takes it off the plugin's hands; a COPY has no parameter for one to name.
      #
      # Everything else about a write the plugin cannot fully read is left to the database rather
      # than refused. When the tables cannot be established at all, or when a table has encrypted
      # columns but which of them this statement writes cannot be enumerated, the plugin cannot be
      # sure a plaintext is at stake, and guessing wrong by refusing would reject legitimate
      # statements that never touch an encrypted column. The required server-side enforcement is what
      # actually guarantees no plaintext reaches an encrypted column; see the plugin docs. The
      # "columns could not be enumerated" case is warned about (the table does hold encrypted
      # columns, so it is worth a line), the "tables unknown" case is left to debug (it usually is
      # not relevant at all).
      #
      # @param tables [Array<String>] the tables the statement writes to
      # @raise [Errors::MetadataError] only for the confirmed-encrypted, cannot-encrypt case above
      def check_write(analysis, tables, annotations)
        copy = analysis.query_type == Utils::Parser::QueryType::COPY

        if tables.empty?
          logger.debug { 'The kms_encryption plugin could not establish the tables a write targets; leaving it to the database' }
          return
        end

        # A COPY has no bind parameter for an annotation to name, so an annotation cannot make one of
        # its columns encryptable and does not excuse it.
        named = copy ? Set.new : annotated_columns(annotations, tables)
        # An unbound column with no table of its own is matched against the statement's tables in
        # order (see resolve_column). In the rare multi-table write where the same bare column name is
        # encrypted in one table but written unbound in another, this can refuse a write that never
        # touches the encrypted column. That is fail-closed and the annotation is the way out of it, so
        # it is left as is rather than complicated further.
        unencryptable = analysis.unbound_write_columns.find do |column|
          config = encrypted_column(column, tables)
          config && !named.include?(config.column_identifier)
        end
        raise unencryptable_write_error(unencryptable, copy: copy) if unencryptable
        return if analysis.write_columns_complete || (annotations.any? && !copy)

        hidden = tables.find { |table| encrypted_columns_of(table).any? }
        logger.warn(unreadable_columns_warning(hidden)) if hidden
      end

      # The encrypted columns the statement's own annotations name.
      #
      # @return [Set<String>] column identifiers, empty when nothing was annotated
      def annotated_columns(annotations, tables)
        annotations.each_value.with_object(Set.new) do |reference, named|
          config = resolve_column(reference, tables)
          named << config.column_identifier if config
        end
      end

      # @param column [Utils::Parser::ColumnInfo]
      # @return [ColumnEncryptionConfig, nil] nil when the column is not encrypted
      def encrypted_column(column, tables)
        reference = column.table_name.nil? ? column.column_name : "#{column.table_name}.#{column.column_name}"
        resolve_column(reference, tables)
      end

      # The encrypted columns a statement reads. Always lenient: a column whose configuration
      # cannot be read is simply not decrypted.
      #
      # @return [Hash{String => ColumnEncryptionConfig}] by column name
      def column_configs(sql)
        return {} unless ready_for_statement?(sql)

        annotations = Utils::Parser::EncryptionAnnotationParser.parse_annotations(sql)
        tables = statement_tables(analysis_of(stripped_sql(sql)), annotations)
        return {} if tables.empty?

        # When two of the statement's tables encrypt a column of the same name, the first of them
        # wins: without the column's table qualifier in the row there is nothing better to go on.
        tables.each_with_object({}) do |table, columns|
          encrypted_columns_of(table).each do |config|
            next unless usable?(config)

            columns[config.column_name] ||= config
          end
        end
      end

      # The tables a statement could be encrypting a column of. An annotation's table qualifier is
      # included as well, since it may name a table the parser did not report.
      #
      # @param analysis [Utils::Parser::SqlParser::SqlAnalysisResult]
      # @return [Array<String>]
      def statement_tables(analysis, annotations)
        tables = analysis.affected_tables.to_a
        annotations.each_value do |reference|
          table = reference.to_s.rpartition('.').first
          next if table.empty?

          table = table.split('.').last
          tables << table unless tables.include?(table)
        end

        tables
      end

      # @param reference [String] either +"column"+ or +"table.column"+
      # @param tables [Array<String>] the tables the statement touches, tried in order
      # @return [ColumnEncryptionConfig, nil] nil when the column is not encrypted
      def resolve_column(reference, tables)
        table, _, column = reference.to_s.rpartition('.')
        return nil if column.empty?

        # What qualifies a column is tried as a table first, and the statement's own tables after
        # it, because the qualifier may be an alias: +/*@encrypt:u.ssn*/+ on a statement that says
        # +UPDATE users u+ names a real column of a real table, and looking only for a table called
        # +u+ would find nothing and leave the value unencrypted.
        candidates = table.empty? ? tables : [table.split('.').last, *tables].uniq
        candidates.each do |candidate|
          config = column_config(candidate, column)
          return config if config
        end

        nil
      end

      def column_config(table, column)
        return nil if unreadable_name?("#{table}.#{column}")

        config = metadata_lookup("#{table}.#{column}") { |manager| manager.column_config(table, column) }
        usable?(config) ? config : nil
      end

      def encrypted_columns_of(table)
        return [] if unreadable_name?(table)

        metadata_lookup(table) { |manager| manager.table_configs(table) } || []
      end

      # A name with a character the SQL's encoding had no UTF-8 form for cannot be matched against the
      # configuration reliably: looking it up would miss, and the column would be treated as though it
      # were not encrypted without anyone knowing. So it is not looked up. The column is left as the
      # database holds it, which is where the required server-side enforcement stops a plaintext being
      # stored, and a warning says why, once for each name, since it only happens when the connection's
      # encoding is one Ruby cannot fully read.
      #
      # @param name [String] a table, or a +"table.column"+ reference
      def unreadable_name?(name)
        return false unless name.include?(UNREADABLE_CHARACTER)
        return true unless @unreadable_names.add?(name)

        logger.warn(
          "The kms_encryption plugin cannot read the name #{name} in the connection's encoding, so it cannot " \
          'tell whether it is encrypted; leaving it to the database. Use a UTF-8 connection, or ASCII names ' \
          'for encrypted tables and columns.'
        )
        true
      end

      # A lookup that fails is never allowed to take the application's statement down with it: the
      # column is left as the database holds it, which is what the application would have got without
      # the plugin, and the required server-side enforcement is what stops a plaintext being stored.
      #
      # @param described [String] what was being looked up, named in the log message
      def metadata_lookup(described)
        manager = metadata_manager
        return nil if manager.nil?

        yield(manager)
      rescue Errors::MetadataError => e
        logger.warn("Could not read the kms_encryption configuration of #{described}: #{e.message}")
        nil
      end

      def usable?(config)
        return false if config.nil?
        return true if config.usable?

        logger.warn("Skipping #{config.column_identifier}: its kms_encryption configuration is incomplete")
        false
      end

      # A column the plugin confirmed is encrypted but that this statement writes with something
      # other than a bind parameter. The value cannot be encrypted, so the write is refused rather
      # than storing a plaintext in a column configured to be encrypted - the one write-side case the
      # plugin fails closed on, since it has positively identified the problem.
      #
      # @param column [Utils::Parser::ColumnInfo] the confirmed-encrypted column written unencryptably
      # @param copy [Boolean] whether the statement is a COPY, which no annotation can rescue
      def unencryptable_write_error(column, copy:)
        advice = if copy
                   'a COPY sends its rows to the server as a stream rather than as bind parameters, which ' \
                     'cannot be encrypted. Write the rows with INSERT and bind the values instead.'
                 else
                   'this statement writes it with something other than a bind parameter, which cannot be ' \
                     'encrypted. Bind the value, or name the parameter it belongs to with an ' \
                     '/*@encrypt:table.column*/ annotation.'
                 end
        Errors::MetadataError
          .validation_failed("#{column.column_name} is configured for kms_encryption, but #{advice}")
          .with_table(column.table_name)
          .with_column(column.column_name)
      end

      # @param table [String] a table of the statement that has encrypted columns
      # @return [String] the warning logged when a write's columns cannot be enumerated
      def unreadable_columns_warning(table)
        "#{table} has columns configured for kms_encryption and which of them this statement writes could " \
          'not be established, so the plugin cannot encrypt them; relying on the database to reject a ' \
          'plaintext. Name the columns the statement writes, or annotate the parameters, to have the plugin ' \
          'encrypt them.'
      end

      def stripped_sql(sql)
        Utils::Parser::EncryptionAnnotationParser.strip_annotations(sql)
      end

      # -- Lazily built collaborators --

      # Builds the parts of the plugin that need a database connection, the first time a statement
      # could touch an encrypted column.
      #
      # @return [Boolean] whether the plugin is ready to encrypt and decrypt
      def ready_for_statement?(sql)
        return false if sql.nil? || sql.to_s.strip.empty?

        error = readiness_error
        return true if error.nil?

        # The application's statement is never the place to report that the kms_encryption tables
        # cannot be read: every column stays as the database holds it until they can, and the
        # required server-side enforcement is what stops a plaintext being stored meanwhile.
        logger.warn("The kms_encryption plugin is not ready, leaving columns as they are: #{error.message}")
        false
      end

      # @return [Errors::MetadataError, nil] nil once the plugin is ready to encrypt and decrypt
      def readiness_error
        @encryption_utility.ensure_initialized
        return nil unless @encryption_utility.metadata_manager.nil?

        Errors::MetadataError.load_failed('The kms_encryption metadata manager could not be built')
      rescue Errors::MetadataError => e
        e
      rescue StandardError => e
        Errors::MetadataError.load_failed("The kms_encryption plugin is not ready: #{e.message}")
      end

      def new_cipher
        Encryption::ColumnCipher.new(key_manager: @encryption_utility.key_manager, sql_runner: sql_runner)
      end

      def metadata_manager
        @encryption_utility.metadata_manager
      end

      def audit_logger
        @encryption_utility.audit_logger
      end

      def sql_runner
        @encryption_utility.sql_runner
      end

      attr_reader :sql_parser
    end
  end
end
