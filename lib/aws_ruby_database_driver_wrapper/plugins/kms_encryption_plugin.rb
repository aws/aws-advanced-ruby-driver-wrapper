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

require_relative '../logging'
require_relative '../ruby_method'
require_relative '../utils/parser/encryption_annotation_parser'
require_relative '../utils/parser/query_type'
require_relative '../utils/parser/sql_parser'
require_relative 'encryption/column_cipher'
require_relative 'encryption/errors'
require_relative 'encryption/kms_encryption_utility'

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
    # such columns through +#each+, +#to_a+, +#[]+ or +PG::Result#field_values+ instead.
    #
    # A read and a write behave differently when the encryption configuration itself cannot be
    # read. A read is lenient: the column is handed to the application exactly as the database
    # holds it, which is what the application would have got without the plugin. A write fails
    # closed and raises, because leaving the column alone there means storing the plaintext in a
    # column that is configured to be encrypted.
    #
    # For the same reason a write fails closed when the value it stores is not one the plugin can
    # replace, or when which columns the statement writes cannot be established at all. A value
    # written into the SQL text, an expression, a DEFAULT, a nested SELECT, an INSERT that does not
    # name its columns: none of these can be encrypted, and a column written in the clear reads back
    # in the clear ever after, since the read path only decrypts a value whose integrity check
    # passes. An annotation overrides this, since it says which column a parameter belongs to.
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
      # a statement that carries its values in its own text is exactly the one that could store a
      # plaintext in an encrypted column, so they are checked all the same.
      WRITE_CHECK_METHODS = Set[
        RubyMethod::CONNECTION_QUERY.name,
        RubyMethod::CONNECTION_QUERY_ASYNC.name
      ].freeze

      # Result methods that hand out whole rows, keyed by column name.
      ROW_METHODS = Set[
        RubyMethod::RESULT_EACH.name,
        RubyMethod::RESULT_TO_A.name,
        RubyMethod::RESULT_BRACKET.name
      ].freeze

      # The result method that hands out every value of one named column.
      COLUMN_VALUES_METHOD = RubyMethod::RESULT_FIELD_VALUES.name

      # Statement types whose bind parameters are stored. A configuration lookup that fails while
      # one of these is being prepared cannot be shrugged off: the plugin would let the plaintext
      # through to a column that is configured to be encrypted, and since the read path only
      # decrypts payloads that pass their integrity check, the row would read back cleanly ever
      # after and nothing would surface the leak. These statements therefore fail closed.
      WRITE_QUERY_TYPES = Set[
        Utils::Parser::QueryType::INSERT,
        Utils::Parser::QueryType::UPDATE
      ].freeze

      # A statement that stores values, as far as its first keyword goes. The keyword is looked at
      # as well as the parse, because a statement the parser could not read has no query type, and
      # that is precisely the case that must not be mistaken for a read.
      WRITE_KEYWORDS = /\A[\s(]*(?:INSERT|UPDATE|REPLACE|UPSERT|MERGE)\b/i

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
        return if context.nil? || sql.nil?

        position = PARAMETER_METHODS[method_name]
        parameters = position.nil? ? args : args[position]
        parameters = [] unless parameters.is_a?(Array)

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
      # @raise [Errors::MetadataError] when the statement stores values and either the encryption
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
      # An annotation is how all of this is overridden. It names the column a parameter belongs to
      # explicitly, so a statement that carries one is taken at its word.
      #
      # @param tables [Array<String>] the tables the statement writes to
      # @raise [Errors::MetadataError]
      def verify_write(analysis, tables, annotations)
        return unless annotations.empty?
        raise unreadable_statement_error if tables.empty?

        unencryptable = analysis.unbound_write_columns.find { |column| encrypted_column(column, tables) }
        raise unencryptable_value_error(unencryptable) if unencryptable
        return if analysis.write_columns_complete

        hidden = tables.find { |table| encrypted_columns_of(table, strict: true).any? }
        raise unreadable_columns_error(hidden) if hidden
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

        candidates = table.empty? ? tables : [table.split('.').last]
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

        logger.warn("Could not read the encryption configuration of #{described}: #{e.message}")
        nil
      end

      def usable?(config, strict: false)
        return false if config.nil?
        return true if config.usable?

        raise incomplete_config_error(config) if strict

        logger.warn("Skipping #{config.column_identifier}: its encryption configuration is incomplete")
        false
      end

      # A column that is configured for encryption but whose key metadata is unusable is in the
      # same position as one whose configuration could not be read at all, and must not be stored
      # in the clear either.
      def incomplete_config_error(config)
        Errors::MetadataError
          .validation_failed("The encryption configuration of #{config.column_identifier} is incomplete")
          .with_table(config.table_name)
          .with_column(config.column_name)
      end

      # @param column [Utils::Parser::ColumnInfo] a column the statement writes without binding
      def unencryptable_value_error(column)
        Errors::MetadataError
          .validation_failed(
            "#{column.column_name} is configured for encryption, but this statement writes it with " \
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
            "#{table} has columns configured for encryption, and which of them this statement " \
            'writes could not be established, so a value could be stored in the clear. Have the ' \
            'statement name the columns it writes, or name the column each parameter belongs to ' \
            'with an /*@encrypt:table.column*/ annotation.'
          )
          .with_table(table)
      end

      def unreadable_statement_error
        Errors::MetadataError.validation_failed(
          'This statement stores values, and neither the tables nor the columns it writes could be ' \
          'established, so whether it writes an encrypted column is unknown. Name the column each ' \
          'parameter belongs to with an /*@encrypt:table.column*/ annotation.'
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

        # On a read the application's statement is not the place to report that the encryption
        # tables cannot be read; every column stays as the database holds it until they can. A
        # statement that stores its parameters asks for the strict form instead, because there the
        # plugin cannot tell whether the statement targets an encrypted column, and guessing that
        # it does not would store the plaintext.
        logger.warn("The KMS encryption plugin is not ready, leaving columns as they are: #{error.message}")
        false
      end

      # @return [Errors::MetadataError, nil] nil once the plugin is ready to encrypt and decrypt
      def readiness_error
        @encryption_utility.ensure_initialized
        return nil unless @encryption_utility.metadata_manager.nil?

        Errors::MetadataError.load_failed('The encryption metadata manager could not be built')
      rescue Errors::MetadataError => e
        e
      rescue StandardError => e
        Errors::MetadataError.load_failed("The KMS encryption plugin is not ready: #{e.message}")
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
