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

require_relative '../../logging'
require_relative '../../ruby_method'
require_relative '../../utils/parser/encryption_annotation_parser'
require_relative '../../utils/parser/query_type'
require_relative '../../utils/parser/sql_parser'
require_relative 'column_cipher'
require_relative 'errors'
require_relative 'kms_encryption_utility'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    # Encrypts and decrypts individual table columns with keys held in AWS KMS, without the
    # application having to know about it.
    #
    # Which columns are encrypted is configured in the database itself, in the
    # +encryption_metadata+ table, so it can be changed without redeploying the application. When a
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
    # Decrypted values are returned as strings, which is what both drivers return for a text column.
    # Rows read as arrays rather than hashes cannot be decrypted, because the plugin has no column
    # names to match against the configuration: +PG::Result#each_row+, +#values+, +#column_values+
    # and +#tuple+, and mysql2's +as: :array+ option, all return values as they are stored. Read
    # such columns through +#each+, +#to_a+, +#[]+ or +PG::Result#field_values+ instead. A
    # +COPY ... TO+ hands out what the column holds as well, since its rows are a stream rather than
    # values the plugin can replace.
    #
    # A read and a write behave differently when the kms_encryption configuration itself cannot be
    # read. A read is lenient: the column is handed to the application exactly as the database
    # holds it, which is what the application would have got without the plugin. A write fails
    # closed and raises, because leaving the column alone there means storing the plaintext in a
    # column that is configured to be encrypted.
    #
    # For the same reason a write fails closed when the value it stores is not one the plugin can
    # replace, or when which columns the statement writes cannot be established at all. A value
    # written into the SQL text, an expression, a DEFAULT, a nested SELECT, an INSERT that does not
    # name its columns, a +COPY ... FROM+: none of these can be encrypted, and a column written in
    # the clear reads back in the clear ever after, since the read path only decrypts a value whose
    # integrity check passes. An annotation overrides this, since it says which column a parameter
    # belongs to, with the one exception of a COPY, which has no parameter for an annotation to name.
    # A COPY is also turned away as it is opened rather than part way through its stream, since the
    # statement that opens it is the last point at which anything can be said about it.
    #
    # A prepared statement is run by name, so the plugin reads the statement the connection remembers
    # preparing under that name, whether it was prepared by the driver's own +prepare+ or by a
    # +PREPARE+ sent as a statement. A name it has no statement for, which is a statement prepared
    # somewhere the connection could not read, is refused when values are bound to it, there being no
    # statement to place them in. A read prepared that way is refused along with the writes, since
    # without the statement there is no telling one from the other. A +PREPARE+ is also checked as it
    # is sent, and not only when its name is later run, since a value written into the statement it
    # carries rather than left as a parameter is only in hand while the +PREPARE+ itself is.
    #
    # None of that amounts to a guarantee that an encrypted column never holds a plaintext, and it
    # should not be read as one. These checks cover the statements this wrapper sends, which is not
    # the same as every statement the column sees: psql, a migration, another service, and whatever
    # was in the table before the column was configured all reach it without passing through here.
    # They are not exhaustive even for what does pass through, since some statements carry their
    # values somewhere the plugin cannot see them at all, +LOAD DATA INFILE+, a +CALL+, a
    # data-modifying common table expression and the second statement of a multi-statement string
    # among them. What the checks are is an early and local failure in place of a plaintext stored
    # silently in a column configured to be encrypted. Enforcing what the column itself may hold is
    # the database's to do, with a constraint or a trigger that checks a value's integrity tag as it
    # goes in, which it can do without help from the application because the HMAC key is stored in
    # +key_storage+.
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

      # Statement methods that take no bind parameters. There is nothing to encrypt for these, but
      # a statement that carries its values outside its bind parameters is exactly the one that could
      # store a plaintext in an encrypted column, so they are checked all the same.
      #
      # mysql2's +query+ covers its asynchronous path as well, since that is the same call with
      # +async: true+ passed to it, and the statement is inspected when it is sent either way.
      #
      # pg's +copy_data+ is here because it opens its COPY on the driver's own connection rather than
      # through the wrapper, so the statement would otherwise never be seen. Checking it when the COPY
      # is opened is what makes checking the calls that feed it unnecessary: a COPY that would store a
      # plaintext is refused before there is anywhere to put a row.
      WRITE_CHECK_METHODS = Set[
        RubyMethod::CONNECTION_QUERY.name,
        RubyMethod::CONNECTION_COPY_DATA.name
      ].freeze

      # Result methods that hand out whole rows, keyed by column name.
      ROW_METHODS = Set[
        RubyMethod::RESULT_EACH.name,
        RubyMethod::RESULT_TO_A.name,
        RubyMethod::RESULT_BRACKET.name
      ].freeze

      # The result method that hands out every value of one named column.
      COLUMN_VALUES_METHOD = RubyMethod::RESULT_FIELD_VALUES.name

      # Statement types that store values. A configuration lookup that fails while one of these is
      # being prepared cannot be shrugged off: the plugin would let the plaintext through to a column
      # that is configured to be encrypted, and since the read path only decrypts payloads that pass
      # their integrity check, the row would read back cleanly ever after and nothing would surface
      # the leak. These statements therefore fail closed.
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

      SUBSCRIBED_METHODS = (
        Set[RubyMethod::CONNECTION_CLOSE.name, COLUMN_VALUES_METHOD] +
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
        @subscribed_methods = SUBSCRIBED_METHODS
      end

      # The administrative interface, for creating master keys and configuring columns.
      #
      # @return [Encryption::KeyManagementUtility]
      def key_management_utility
        @encryption_utility.key_management_utility
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
        elsif method_name == COLUMN_VALUES_METHOD
          read_column_values(pipeline_callable, args.first, sql)
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
        return verify_unknown_statement(parameters) if sql.nil?

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

      # A call whose statement the wrapper never saw, which is a prepared statement run by name after
      # something other than a +prepare+ or a +PREPARE+ brought it into being: one prepared inside a
      # multi-statement string, or on the driver's connection directly, or by a client library of its
      # own devising. Values bound to it cannot be placed, there being no statement to place them in,
      # so a call that binds any is refused rather than sending them as they are, this being the one
      # path where a plaintext would reach an encrypted column silently and read back clean ever
      # after. A call that binds nothing has nothing to leak and is let through.
      #
      # A read prepared that way is refused along with the writes, since without the statement there
      # is no telling one from the other.
      #
      # @raise [Errors::MetadataError]
      def verify_unknown_statement(parameters)
        raise unknown_statement_error unless parameters.empty?
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
          parameters.each_with_index do |value, index|
            config = columns[index + 1]
            next if config.nil? || value.nil?

            encrypted ||= parameters.dup
            encrypted[index] = bind_value(encrypt_value(value, config, cipher))
          end
        ensure
          cipher.release
        end

        encrypted
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
        caller_block = context&.block

        begin
          if method_name == RubyMethod::RESULT_EACH.name && caller_block
            # each yields the rows rather than returning them, so the block is what has to be
            # decrypted through. Replacing it in the call context leaves the caller's own block
            # untouched.
            context.block = proc { |row, *rest| caller_block.call(decrypt_row(row, columns, cipher), *rest) }
            pipeline_callable.call
          elsif method_name == RubyMethod::RESULT_EACH.name
            # each called without a block returns an Enumerator over the rows. The rows are decrypted
            # eagerly and handed back as an enumerator over the results, because the cipher is released
            # as soon as this method returns and a lazy wrapper would decrypt with a spent cipher.
            result = pipeline_callable.call
            result.respond_to?(:map) ? result.map { |row| decrypt_row(row, columns, cipher) }.each : result
          elsif method_name == RubyMethod::RESULT_TO_A.name
            rows = pipeline_callable.call
            rows.is_a?(Array) ? rows.map { |row| decrypt_row(row, columns, cipher) } : rows
          else
            decrypt_row(pipeline_callable.call, columns, cipher)
          end
        ensure
          cipher.release
        end
      end

      def read_column_values(pipeline_callable, field_name, sql)
        config = field_name.nil? ? nil : column_configs(sql)[field_name.to_s]
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
      #   statement, by column name
      # @return [Object] the row, with a new hash substituted only when something was decrypted
      def decrypt_row(row, columns, cipher)
        return row unless row.is_a?(Hash)

        decrypted = nil
        columns.each do |column_name, config|
          next unless row.key?(column_name)

          raw = row[column_name]
          next unless cipher.encrypted_payload?(raw)

          value = decrypt_value(raw, config, cipher)
          next if value.equal?(raw)

          decrypted ||= row.dup
          decrypted[column_name] = value
        end

        decrypted || row
      end

      def decrypt_value(raw, config, cipher)
        cipher.decrypt(raw, config)
      rescue StandardError => e
        audit_logger.log_decryption(
          table_name: config.table_name, column_name: config.column_name, key_id: config.key_id,
          success: false, error_message: e.message
        )
        raise
      end

      # -- Statement analysis --

      # The encrypted columns a statement's bind parameters write to.
      #
      # The statement is parsed before the plugin is made ready, since the parse says whether the
      # statement stores its parameters and so whether a configuration that cannot be read has to
      # be raised rather than logged.
      #
      # @return [Hash{Integer => ColumnEncryptionConfig}] by 1-based parameter index
      # @raise [Errors::MetadataError] when the statement stores values and either the kms_encryption
      #   configuration cannot be read or the values cannot be encrypted
      def parameter_columns(sql)
        annotations = Utils::Parser::EncryptionAnnotationParser.parse_annotations(sql)
        stripped = stripped_sql(sql)
        analysis = analysis_of(stripped)
        strict = write_statement?(analysis, stripped)
        inferred = analysis.parameter_column_names
        return {} if !strict && annotations.empty? && inferred.empty?
        return {} unless ready_for_statement?(sql, strict: strict)

        tables = statement_tables(analysis, annotations)
        verify_write(analysis, tables, annotations) if strict

        inferred.merge(annotations).each_with_object({}) do |(index, reference), columns|
          config = resolve_column(reference, tables, strict: strict)
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

      # What a statement that stores values has to satisfy before any of them go to the server.
      #
      # The plugin can only encrypt a value that reaches the server as a bind parameter, and only
      # when it knows which column that parameter fills. A write it cannot read that far fails
      # rather than letting the value through: a column written in the clear reads back in the clear
      # ever after, because the read path only decrypts a value whose integrity check passes, so
      # nothing would ever surface the leak.
      #
      # An annotation is how all of this is overridden, but only as far as it reaches. It names the
      # column one parameter belongs to, so that column is taken as the caller's own business and
      # not held against the statement, while a second encrypted column the same statement writes in
      # the clear is still refused. Which parameter fills which column is the one thing an
      # annotation settles for the whole statement, since a caller that maps one parameter by hand is
      # saying the parser's reading is not the one to go by. A COPY is outside all of this, having no
      # parameter for an annotation to name.
      #
      # @param tables [Array<String>] the tables the statement writes to
      # @raise [Errors::MetadataError]
      def verify_write(analysis, tables, annotations)
        return verify_copy(analysis, tables) if analysis.query_type == Utils::Parser::QueryType::COPY
        raise unreadable_statement_error if tables.empty?

        named = annotated_columns(annotations, tables)
        unencryptable = analysis.unbound_write_columns.find do |column|
          config = encrypted_column(column, tables)
          config && !named.include?(config.column_identifier)
        end
        raise unencryptable_value_error(unencryptable) if unencryptable
        return if analysis.write_columns_complete || annotations.any?

        hidden = tables.find { |table| encrypted_columns_of(table, strict: true).any? }
        raise unreadable_columns_error(hidden) if hidden
      end

      # The encrypted columns the statement's own annotations name.
      #
      # @return [Set<String>] column identifiers, empty when nothing was annotated
      def annotated_columns(annotations, tables)
        annotations.each_value.with_object(Set.new) do |reference, named|
          config = resolve_column(reference, tables, strict: true)
          named << config.column_identifier if config
        end
      end

      # A COPY sends its rows to the server as a stream rather than as bind parameters, so there is
      # nothing for the plugin to replace and none of its columns can be encrypted. It is refused
      # when it names an encrypted column, and when it names no columns at all and the table it
      # writes has any, since then the table's own column order decides what it fills.
      #
      # This is the one write an annotation does not excuse: there is no parameter for one to name,
      # so it cannot say anything that would make the rows encryptable.
      #
      # The check happens when the COPY is opened, which is why the calls that feed it need no check
      # of their own. Both the +copy_data+ form and a +COPY ... FROM STDIN+ sent as a statement of
      # its own arrive here.
      #
      # @param tables [Array<String>] the tables the statement writes to
      # @raise [Errors::MetadataError]
      def verify_copy(analysis, tables)
        raise unreadable_statement_error if tables.empty?

        column = analysis.unbound_write_columns.find { |candidate| encrypted_column(candidate, tables) }
        raise copy_write_error(column.table_name || tables.first, column.column_name) if column
        return if analysis.write_columns_complete

        hidden = tables.find { |table| encrypted_columns_of(table, strict: true).any? }
        raise copy_write_error(hidden) if hidden
      end

      # @param column [Utils::Parser::ColumnInfo]
      # @return [ColumnEncryptionConfig, nil] nil when the column is not encrypted
      def encrypted_column(column, tables)
        reference = column.table_name.nil? ? column.column_name : "#{column.table_name}.#{column.column_name}"
        resolve_column(reference, tables, strict: true)
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
      # @param strict [Boolean] whether a configuration that cannot be read must be raised
      # @return [ColumnEncryptionConfig, nil] nil when the column is not encrypted
      def resolve_column(reference, tables, strict: false)
        table, _, column = reference.to_s.rpartition('.')
        return nil if column.empty?

        # What qualifies a column is tried as a table first, and the statement's own tables after
        # it, because the qualifier may be an alias: +/*@encrypt:u.ssn*/+ on a statement that says
        # +UPDATE users u+ names a real column of a real table, and looking only for a table called
        # +u+ would find nothing and leave the value unencrypted.
        candidates = table.empty? ? tables : [table.split('.').last, *tables].uniq
        candidates.each do |candidate|
          config = column_config(candidate, column, strict: strict)
          return config if config
        end

        nil
      end

      def column_config(table, column, strict: false)
        config = metadata_lookup("#{table}.#{column}", strict: strict) do |manager|
          manager.column_config(table, column)
        end
        usable?(config, strict: strict) ? config : nil
      end

      def encrypted_columns_of(table, strict: false)
        metadata_lookup(table, strict: strict) { |manager| manager.table_configs(table) } || []
      end

      # @param described [String] what was being looked up, named in the log message
      # @param strict [Boolean] whether a failed lookup must be raised rather than logged
      def metadata_lookup(described, strict: false)
        manager = metadata_manager
        return nil if manager.nil?

        yield(manager)
      rescue Errors::MetadataError => e
        # On a read, a lookup that fails must not take the application's statement down with it:
        # the column is left as the database holds it, which is what the application would have
        # got without the plugin. A statement that stores the value has no such safe fallback,
        # since leaving the column alone means storing the plaintext.
        raise if strict

        logger.warn("Could not read the kms_encryption configuration of #{described}: #{e.message}")
        nil
      end

      def usable?(config, strict: false)
        return false if config.nil?
        return true if config.usable?

        raise incomplete_config_error(config) if strict

        logger.warn("Skipping #{config.column_identifier}: its kms_encryption configuration is incomplete")
        false
      end

      # A column that is configured for kms_encryption but whose key metadata is unusable is in the
      # same position as one whose configuration could not be read at all, and must not be stored
      # in the clear either.
      def incomplete_config_error(config)
        Errors::MetadataError
          .validation_failed("The kms_encryption configuration of #{config.column_identifier} is incomplete")
          .with_table(config.table_name)
          .with_column(config.column_name)
      end

      # @param column [Utils::Parser::ColumnInfo] a column the statement writes without binding
      def unencryptable_value_error(column)
        Errors::MetadataError
          .validation_failed(
            "#{column.column_name} is configured for kms_encryption, but this statement writes it with " \
            'something other than a bind parameter, which cannot be encrypted. Bind the value, or ' \
            'name the parameter it belongs to with an /*@encrypt:table.column*/ annotation.'
          )
          .with_table(column.table_name)
          .with_column(column.column_name)
      end

      # @param table [String] a table of the statement that has encrypted columns
      def unreadable_columns_error(table)
        Errors::MetadataError
          .validation_failed(
            "#{table} has columns configured for kms_encryption, and which of them this statement " \
            'writes could not be established, so a value could be stored in the clear. Have the ' \
            'statement name the columns it writes, or name the column each parameter belongs to ' \
            'with an /*@encrypt:table.column*/ annotation.'
          )
          .with_table(table)
      end

      # An annotation is no way out of this one, since a COPY has no parameter for one to name, so the
      # only advice worth giving is to write the rows some other way.
      #
      # @param table [String] the table the COPY writes
      # @param column [String, nil] the encrypted column it names, when it names its columns at all
      def copy_write_error(table, column = nil)
        subject = column ? "#{table}.#{column} is configured for kms_encryption" : "#{table} has columns configured for kms_encryption"
        Errors::MetadataError
          .validation_failed(
            "#{subject}, and a COPY sends its rows to the server as a stream rather than as bind " \
            'parameters, which cannot be encrypted. Write the rows with INSERT and bind the values instead.'
          )
          .with_table(table)
          .with_column(column)
      end

      def unreadable_statement_error
        Errors::MetadataError.validation_failed(
          'This statement stores values, and neither the tables nor the columns it writes could be ' \
          'established, so whether it writes an encrypted column is unknown. Name the column each ' \
          'parameter belongs to with an /*@encrypt:table.column*/ annotation.'
        )
      end

      def unknown_statement_error
        Errors::MetadataError.validation_failed(
          'This call binds values to a prepared statement whose text this connection never saw, so ' \
          'which column each value belongs to is unknown and a value could be stored in the clear. ' \
          "Prepare the statement with the connection's prepare, or with a PREPARE sent on its own."
        )
      end

      def stripped_sql(sql)
        Utils::Parser::EncryptionAnnotationParser.strip_annotations(sql)
      end

      # -- Lazily built collaborators --

      # Builds the parts of the plugin that need a database connection, the first time a statement
      # could touch an encrypted column.
      #
      # @param strict [Boolean] whether being unable to make the plugin ready must be raised
      # @return [Boolean] whether the plugin is ready to encrypt and decrypt
      # @raise [Errors::MetadataError] when strict and the plugin cannot be made ready
      def ready_for_statement?(sql, strict: false)
        return false if sql.nil? || sql.to_s.strip.empty?

        error = readiness_error
        return true if error.nil?
        raise error if strict

        # On a read the application's statement is not the place to report that the kms_encryption
        # tables cannot be read; every column stays as the database holds it until they can. A
        # statement that stores its parameters asks for the strict form instead, because there the
        # plugin cannot tell whether the statement targets an encrypted column, and guessing that
        # it does not would store the plaintext.
        logger.warn("The KMS kms_encryption plugin is not ready, leaving columns as they are: #{error.message}")
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
        Errors::MetadataError.load_failed("The KMS kms_encryption plugin is not ready: #{e.message}")
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

      def sql_parser
        @sql_parser ||= Utils::Parser::SqlParser.new(@service_container.dialect_service.driver_dialect)
      end
    end
  end
end
