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

      # Result methods that hand out whole rows, keyed by column name.
      ROW_METHODS = Set[
        RubyMethod::RESULT_EACH.name,
        RubyMethod::RESULT_TO_A.name,
        RubyMethod::RESULT_BRACKET.name
      ].freeze

      # The result method that hands out every value of one named column.
      COLUMN_VALUES_METHOD = RubyMethod::RESULT_FIELD_VALUES.name

      SUBSCRIBED_METHODS = (
        Set[RubyMethod::CONNECTION_CLOSE.name, COLUMN_VALUES_METHOD] + PARAMETER_METHODS.keys + ROW_METHODS
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
        logger.debug('The KMS encryption plugin is loaded')
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

        parameter_index = PARAMETER_METHODS[method_name]
        parameters = parameter_index.nil? ? args : args[parameter_index]
        return unless parameters.is_a?(Array) && !parameters.empty?

        columns = parameter_columns(sql)
        return if columns.empty?

        encrypted = encrypt_each(parameters, columns)
        return if encrypted.nil?

        if parameter_index.nil?
          context.args = encrypted
        else
          rewritten = args.dup
          rewritten[parameter_index] = encrypted
          context.args = rewritten
        end
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
      # @return [Hash{Integer => ColumnEncryptionConfig}] by 1-based parameter index
      def parameter_columns(sql)
        return {} unless initialize_for_statement(sql)

        annotations = Utils::Parser::EncryptionAnnotationParser.parse_annotations(sql)
        inferred = sql_parser.column_parameter_mapping(stripped_sql(sql))
        return {} if annotations.empty? && inferred.empty?

        tables = statement_tables(sql, annotations)
        inferred.merge(annotations).each_with_object({}) do |(index, reference), columns|
          config = resolve_column(reference, tables)
          columns[index] = config if config
        end
      end

      # The encrypted columns a statement reads.
      #
      # @return [Hash{String => ColumnEncryptionConfig}] by column name
      def column_configs(sql)
        return {} unless initialize_for_statement(sql)

        tables = statement_tables(sql, Utils::Parser::EncryptionAnnotationParser.parse_annotations(sql))
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
      # @return [Array<String>]
      def statement_tables(sql, annotations)
        tables = sql_parser.analyze_sql(stripped_sql(sql)).affected_tables.to_a
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

        candidates = table.empty? ? tables : [table.split('.').last]
        candidates.each do |candidate|
          config = column_config(candidate, column)
          return config if config
        end

        nil
      end

      def column_config(table, column)
        config = metadata_lookup("#{table}.#{column}") { |manager| manager.column_config(table, column) }
        usable?(config) ? config : nil
      end

      def encrypted_columns_of(table)
        metadata_lookup(table) { |manager| manager.table_configs(table) } || []
      end

      def metadata_lookup(described)
        manager = metadata_manager
        return nil if manager.nil?

        yield(manager)
      rescue Encryption::Errors::MetadataError => e
        # A metadata lookup that fails must not take the application's statement down with it: the
        # column is left as the database holds it, which is what the application would have got
        # without the plugin.
        logger.warn("Could not read the encryption configuration of #{described}: #{e.message}")
        nil
      end

      def usable?(config)
        return false if config.nil?

        return true if config.usable?

        logger.warn("Skipping #{config.column_identifier}: its encryption configuration is incomplete")
        false
      end

      def stripped_sql(sql)
        Utils::Parser::EncryptionAnnotationParser.strip_annotations(sql)
      end

      # -- Lazily built collaborators --

      # Builds the parts of the plugin that need a database connection, the first time a statement
      # could touch an encrypted column.
      #
      # @return [Boolean] whether the plugin is ready to encrypt and decrypt
      def initialize_for_statement(sql)
        return false if sql.nil? || sql.to_s.strip.empty?

        @encryption_utility.ensure_initialized
        !@encryption_utility.metadata_manager.nil?
      rescue StandardError => e
        # The application's statement is not the place to report that the encryption tables cannot
        # be read; every column stays as the database holds it until they can.
        logger.warn("The KMS encryption plugin is not ready, leaving columns as they are: #{e.message}")
        false
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
