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

require 'base64'
require 'securerandom'
require_relative 'driver_helper'
require_relative 'test_driver'

module Integration
  # Shared setup for the KMS encryption integration specs. Mixed into the example groups (which also
  # carry the 'integration setup' context), so its methods can reach +drv+, +env+, +info+ and
  # +writer+ directly.
  #
  # The KMS master key is supplied out of band, in the KMS_KEY_ID environment variable (the host
  # harness forwards it into the test container), exactly as the JDBC wrapper's encryption tests take
  # it from AWS_KMS_KEY_ARN. Specs skip themselves when it is unset via {#require_kms!}.
  #
  # The encryption schema is set up over a plain (non-plugin) connection the way an administrator or
  # migration would, mirroring the JDBC test's @BeforeAll: the data-path specs deliberately do not go
  # through KeyManagementUtility for setup, so that a bug in the utility cannot mask a bug in the
  # read/write path. Configuring a column asks KMS for a real data key, wraps it, and stores it next
  # to a random HMAC key, which is all the plugin (and any server-side trigger) needs.
  module KmsEncryptionHelper
    DEFAULT_ALGORITHM = 'AES-256-GCM'
    HMAC_KEY_LENGTH = 32
    # Wide enough for any encrypted payload the specs write: 32 (HMAC) + 1 (type) + 12 (IV) +
    # ciphertext + 16 (GCM tag).
    MYSQL_ENCRYPTED_COLUMN_TYPE = 'VARBINARY(512)'

    # -- Configuration --

    # @return [String, nil] the KMS master key identifier (id, ARN, or alias) the specs encrypt with
    def kms_key_id
      value = ENV.fetch('KMS_KEY_ID', nil)
      value.to_s.strip.empty? ? nil : value.strip
    end

    # @return [Boolean] whether a KMS master key and a usable driver are available
    def kms_configured?
      !kms_key_id.nil? && !drv.nil?
    end

    # Skips the example unless a KMS master key and a driver are both available. The encryption specs
    # only run in the dedicated encryption-only environment, and even there they cannot run without a
    # key, so this mirrors the JDBC test's assumeTrue on AWS_KMS_KEY_ARN.
    def require_kms!
      skip 'No allowed driver for this environment' if drv.nil?
      skip 'KMS_KEY_ID is not set; skipping KMS encryption test' if kms_key_id.nil?
    end

    # @return [String] the region KMS calls are made in
    def kms_region
      env.aurora_region
    end

    # The schema that holds encryption_metadata and key_storage. The connection's own database is used
    # so the specs need no CREATE DATABASE / CREATE SCHEMA privilege: on MySQL a schema is a database,
    # and on PostgreSQL 'public' is the default schema of the connection's database.
    #
    # @return [String]
    def metadata_schema
      case drv
      when TestDriver::PG    then 'public'
      when TestDriver::MYSQL then info.default_dbname
      else raise "Unsupported driver: #{drv}"
      end
    end

    # @return [Aws::KMS::Client] a client built from the ambient credentials and the test region
    def kms_client
      @kms_client ||= begin
        require 'aws-sdk-kms'
        Aws::KMS::Client.new(region: kms_region)
      end
    end

    # -- Connections and connection configuration --

    # @return [Hash] the driver-native connection parameters for the writer instance
    def native_params
      DriverHelper.native_config(
        drv, host: writer.host, port: writer.port,
             user: info.username, password: info.password, dbname: info.default_dbname
      )
    end

    # A plain driver connection with no plugins, used for administrative setup and for reading a value
    # at rest (to prove it is stored as ciphertext).
    #
    # On PostgreSQL, notices are quieted to warnings so the idempotent DROP TABLE IF EXISTS statements
    # in setup and teardown do not print a "table ... does not exist, skipping" NOTICE for every table.
    #
    # @return [Object] a pg or mysql2 connection
    def native_connect
      conn = DriverHelper.native_connect(drv, **native_params)
      conn.exec('SET client_min_messages TO warning') if drv == TestDriver::PG
      conn
    end

    # The wrapper properties that turn the kms_encryption plugin on for an application connection.
    #
    # @return [Hash]
    def encryption_props
      {
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::PLUGINS.name => 'kms_encryption',
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::ENCRYPTION_KMS_REGION.name => kms_region,
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::ENCRYPTION_METADATA_SCHEMA.name => metadata_schema
      }
    end

    # An application connection with the kms_encryption plugin enabled.
    #
    # @return [Object] a WrapperPgConnection or WrapperMysql2Client
    def encryption_connect(**extra_props)
      DriverHelper.wrapper_connect(drv, **native_params, **encryption_props, **extra_props)
    end

    # An ActiveRecord connection configuration with the kms_encryption plugin enabled.
    #
    # The SSL option matches what {DriverHelper.native_config} applies for the raw-driver path, so
    # the AR connection can reach an Aurora cluster with require_secure_transport / rds.force_ssl on.
    #
    # prepared_statements is forced on because the plugin can only encrypt a bound parameter: with it
    # off, the mysql2 adapter inlines the value as a literal in the INSERT, which the plugin (rightly)
    # cannot encrypt and refuses. The PostgreSQL adapter already defaults it on; MySQL defaults it off.
    #
    # @return [Hash]
    def encryption_adapter_config
      adapter, ssl = case drv
                     when TestDriver::PG    then ['aws_postgresql', { sslmode: 'require' }]
                     when TestDriver::MYSQL then ['aws_mysql2', { ssl_mode: :required }]
                     else raise "Unsupported driver: #{drv}"
                     end

      {
        adapter: adapter,
        host: writer.host,
        port: writer.port,
        username: info.username,
        password: info.password,
        database: info.default_dbname,
        prepared_statements: true
      }.merge(ssl).merge(encryption_props)
    end

    # -- Schema setup --

    # Installs the two metadata tables the plugin reads, matching the columns SchemaValidator and
    # KeyManager expect. Existing tables are dropped first so a rerun starts clean.
    #
    # @param conn [Object] a plain pg or mysql2 connection
    # @return [void]
    def create_metadata_tables(conn)
      run(conn, "DROP TABLE IF EXISTS #{schema_ref('encryption_metadata')}")
      run(conn, "DROP TABLE IF EXISTS #{schema_ref('key_storage')}")

      case drv
      when TestDriver::PG
        run(conn, <<~SQL)
          CREATE TABLE #{schema_ref('key_storage')} (
            id SERIAL PRIMARY KEY,
            key_id VARCHAR(255) NOT NULL,
            name VARCHAR(255) NOT NULL,
            master_key_arn VARCHAR(512) NOT NULL,
            encrypted_data_key TEXT NOT NULL,
            hmac_key BYTEA NOT NULL,
            key_spec VARCHAR(50) DEFAULT 'AES_256',
            created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            last_used_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP)
        SQL
        run(conn, <<~SQL)
          CREATE TABLE #{schema_ref('encryption_metadata')} (
            table_name VARCHAR(255) NOT NULL,
            column_name VARCHAR(255) NOT NULL,
            encryption_algorithm VARCHAR(50) NOT NULL,
            key_id INTEGER NOT NULL,
            created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (table_name, column_name),
            FOREIGN KEY (key_id) REFERENCES #{schema_ref('key_storage')}(id))
        SQL
      when TestDriver::MYSQL
        run(conn, <<~SQL)
          CREATE TABLE #{schema_ref('key_storage')} (
            id INT AUTO_INCREMENT PRIMARY KEY,
            key_id VARCHAR(255) NOT NULL,
            name VARCHAR(255) NOT NULL,
            master_key_arn VARCHAR(512) NOT NULL,
            encrypted_data_key TEXT NOT NULL,
            hmac_key VARBINARY(32) NOT NULL,
            key_spec VARCHAR(50) DEFAULT 'AES_256',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_used_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
        SQL
        run(conn, <<~SQL)
          CREATE TABLE #{schema_ref('encryption_metadata')} (
            table_name VARCHAR(255) NOT NULL,
            column_name VARCHAR(255) NOT NULL,
            encryption_algorithm VARCHAR(50) NOT NULL,
            key_id INT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (table_name, column_name),
            FOREIGN KEY (key_id) REFERENCES #{schema_ref('key_storage')}(id))
        SQL
      end
    end

    # Creates an application table with plain columns plus one binary column per encrypted column.
    #
    # @param conn [Object]
    # @param table [String]
    # @param encrypted_columns [Array<String>] columns the plugin will encrypt
    # @param plain_columns [Array<String>] additional plaintext VARCHAR columns
    # @param pg_encrypted_type [String] the PostgreSQL type for encrypted columns ('bytea' or
    #   'encrypted_data' once {#install_pg_encrypted_type} has run)
    # @return [void]
    def create_app_table(conn, table, encrypted_columns:, plain_columns: ['name'], pg_encrypted_type: 'bytea')
      run(conn, "DROP TABLE IF EXISTS #{table}")

      case drv
      when TestDriver::PG
        columns = ['id SERIAL PRIMARY KEY']
        plain_columns.each { |c| columns << "#{c} VARCHAR(255)" }
        encrypted_columns.each { |c| columns << "#{c} #{pg_encrypted_type}" }
        run(conn, "CREATE TABLE #{table} (#{columns.join(', ')})")
      when TestDriver::MYSQL
        columns = ['id INT AUTO_INCREMENT PRIMARY KEY']
        plain_columns.each { |c| columns << "#{c} VARCHAR(255)" }
        encrypted_columns.each { |c| columns << "#{c} #{MYSQL_ENCRYPTED_COLUMN_TYPE}" }
        run(conn, "CREATE TABLE #{table} (#{columns.join(', ')})")
      end
    end

    # Configures a column for encryption the way an administrator would: asks KMS for a real data key,
    # stores its wrapped form next to a fresh random HMAC key, and records the column in
    # encryption_metadata. Returns the raw keys so trigger specs can build payloads by hand.
    #
    # @param conn [Object]
    # @param table [String]
    # @param column [String]
    # @param algorithm [String]
    # @return [Hash] :key_id (key_storage.id), :hmac_key and :data_key (both binary strings)
    def configure_column(conn, table, column, algorithm: DEFAULT_ALGORITHM)
      generated = kms_client.generate_data_key(key_id: kms_key_id, key_spec: 'AES_256')
      encrypted_data_key = Base64.strict_encode64(generated.ciphertext_blob)
      hmac_key = SecureRandom.bytes(HMAC_KEY_LENGTH)

      key_id = insert_key(conn, name: "#{table}.#{column}", encrypted_data_key: encrypted_data_key, hmac_key: hmac_key)
      insert_metadata(conn, table: table, column: column, algorithm: algorithm, key_id: key_id)

      { key_id: key_id, hmac_key: hmac_key, data_key: generated.plaintext.dup.b }
    end

    # Full setup for the common case: metadata tables, an application table, and one configured
    # encrypted column per entry in +encrypted_columns+.
    #
    # @param table [String]
    # @param encrypted_columns [Array<String>]
    # @param plain_columns [Array<String>]
    # @return [Hash{String=>Hash}] the {#configure_column} result for each encrypted column
    def provision(conn, table:, encrypted_columns:, plain_columns: ['name'])
      create_metadata_tables(conn)
      create_app_table(conn, table, encrypted_columns: encrypted_columns, plain_columns: plain_columns)
      encrypted_columns.to_h { |column| [column, configure_column(conn, table, column)] }
    end

    # Drops everything {#provision} (and the trigger/type installers) create.
    #
    # @return [void]
    def teardown_encryption(conn, table:)
      run(conn, "DROP TABLE IF EXISTS #{table}")
      run(conn, "DROP TABLE IF EXISTS #{schema_ref('encryption_metadata')}")
      run(conn, "DROP TABLE IF EXISTS #{schema_ref('key_storage')}")
    rescue StandardError
      nil
    end

    # -- Reading a value at rest --

    # Reads a single column value directly, over a plain connection, without decryption. Used to
    # assert a stored value is ciphertext (binary), not the plaintext that was written.
    #
    # @return [String, nil] the raw stored bytes
    def stored_value(conn, table, column, where_column, where_value)
      case drv
      when TestDriver::PG
        result = conn.exec_params("SELECT #{column} FROM #{table} WHERE #{where_column} = $1", [where_value])
        result.ntuples.zero? ? nil : result.getvalue(0, 0)
      when TestDriver::MYSQL
        result = conn.query("SELECT #{column} FROM #{table} WHERE #{where_column} = '#{conn.escape(where_value)}'")
        row = result.first
        row && row[column]
      end
    end

    # -- Low-level helpers --

    # Runs a statement that returns no rows, over a plain connection.
    def run(conn, sql)
      DriverHelper.execute(drv, conn, sql)
    end

    # The schema-qualified name of a metadata table.
    def schema_ref(table)
      "#{metadata_schema}.#{table}"
    end

    # @param bytes [String] a binary string
    # @return [String] its lowercase hex representation
    def hex(bytes)
      bytes.b.unpack1('H*')
    end

    private

    # Inserts a key_storage row and returns its surrogate id, handling the id-return difference
    # between the two drivers.
    def insert_key(conn, name:, encrypted_data_key:, hmac_key:)
      key_uuid = SecureRandom.uuid
      case drv
      when TestDriver::PG
        result = conn.exec_params(
          "INSERT INTO #{schema_ref('key_storage')} " \
          '(key_id, name, master_key_arn, encrypted_data_key, hmac_key, key_spec) ' \
          "VALUES ($1, $2, $3, $4, $5, 'AES_256') RETURNING id",
          [key_uuid, name, kms_key_id, encrypted_data_key, { value: hmac_key, format: 1 }]
        )
        result.getvalue(0, 0).to_i
      when TestDriver::MYSQL
        conn.query(
          "INSERT INTO #{schema_ref('key_storage')} " \
          '(key_id, name, master_key_arn, encrypted_data_key, hmac_key, key_spec) ' \
          "VALUES ('#{key_uuid}', '#{conn.escape(name)}', '#{conn.escape(kms_key_id)}', " \
          "'#{encrypted_data_key}', X'#{hex(hmac_key)}', 'AES_256')"
        )
        conn.last_id
      end
    end

    def insert_metadata(conn, table:, column:, algorithm:, key_id:)
      case drv
      when TestDriver::PG
        conn.exec_params(
          "INSERT INTO #{schema_ref('encryption_metadata')} " \
          '(table_name, column_name, encryption_algorithm, key_id) VALUES ($1, $2, $3, $4)',
          [table, column, algorithm, key_id]
        )
      when TestDriver::MYSQL
        conn.query(
          "INSERT INTO #{schema_ref('encryption_metadata')} " \
          '(table_name, column_name, encryption_algorithm, key_id) ' \
          "VALUES ('#{conn.escape(table)}', '#{conn.escape(column)}', '#{algorithm}', #{key_id.to_i})"
        )
      end
    end
  end
end
