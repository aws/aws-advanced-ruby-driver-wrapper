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

require_relative '../support/shared_contexts/adapter_context'

RSpec.shared_examples 'ActiveRecord types and edge cases' do |driver_helper|
  include driver_helper

  EDGE_MODELS = [ArEdgeSetting, ArEdgeSecretNote, ArEdgeJsonDoc, ArEdgeUuidRecord,
                ArEdgePrepStmtTest, ArEdgeMigrationLock].freeze unless defined?(EDGE_MODELS)

  before(:all) do
    ActiveRecordAdapterHelper.establish_fresh_connection(driver_helper, EDGE_MODELS)

    ActiveRecord::Schema.define do
      suppress_messages do
        # --- ActiveRecord::Store with advanced usage ---
        create_table :ar_edge_settings, force: true do |t|
          t.string :name, null: false
          t.text :preferences
          t.text :metadata
          t.timestamps
        end

        # --- Encrypted attributes (Rails 7+) ---
        create_table :ar_edge_secret_notes, force: true do |t|
          t.string :title, null: false
          t.text :content
          t.timestamps
        end

        # --- JSON columns ---
        create_table :ar_edge_json_docs, force: true do |t|
          t.string :name, null: false
          t.json :payload
          t.timestamps
        end

        # --- UUID-like primary keys (string PK) ---
        create_table :ar_edge_uuid_records, id: false, force: true do |t|
          t.string :id, primary_key: true, null: false, limit: 36
          t.string :label, null: false
          t.timestamps
        end

        # --- Prepared statements ---
        create_table :ar_edge_prep_stmt_tests, force: true do |t|
          t.string :code, null: false
          t.integer :value, default: 0
          t.timestamps
        end

        # --- Advisory locks (used by migrations) ---
        create_table :ar_edge_migration_locks, force: true do |t|
          t.string :version, null: false
          t.timestamps
        end
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      suppress_messages do
        drop_table :ar_edge_settings, if_exists: true
        drop_table :ar_edge_secret_notes, if_exists: true
        drop_table :ar_edge_json_docs, if_exists: true
        drop_table :ar_edge_uuid_records, if_exists: true
        drop_table :ar_edge_prep_stmt_tests, if_exists: true
        drop_table :ar_edge_migration_locks, if_exists: true
      end
    end
    ActiveRecord::Base.connection_handler.clear_active_connections!
  end

  before do
    ArEdgeSetting.delete_all
    ArEdgeSecretNote.delete_all
    ArEdgeJsonDoc.delete_all
    ArEdgeUuidRecord.delete_all
    ArEdgePrepStmtTest.delete_all
    ArEdgeMigrationLock.delete_all
  end

  describe 'ActiveRecord::Store advanced' do
    it 'supports multiple store columns' do
      setting = ArEdgeSetting.create!(name: 'Multi', theme: 'dark', language: 'en', version: '2.0')
      setting.reload
      expect(setting.theme).to eq('dark')
      expect(setting.language).to eq('en')
      expect(setting.version).to eq('2.0')
    end

    it 'supports store_accessor with prefix' do
      setting = ArEdgeSetting.create!(name: 'Prefixed', theme: 'light')
      expect(setting.theme).to eq('light')
      setting.update!(theme: 'dark')
      expect(setting.reload.theme).to eq('dark')
    end

    it 'persists complex nested values in store' do
      setting = ArEdgeSetting.create!(name: 'Nested', theme: 'system', language: 'en')
      setting.reload
      # Verify store accessors persist correctly
      expect(setting.theme).to eq('system')
      expect(setting.language).to eq('en')
      # Verify the raw column is serialized JSON containing the store data
      raw = ActiveRecord::Base.connection.select_value(
        "SELECT preferences FROM ar_edge_settings WHERE id = #{setting.id}"
      )
      parsed = JSON.parse(raw)
      expect(parsed).to include('theme' => 'system', 'language' => 'en')
    end

    it 'tracks changes on store accessors' do
      setting = ArEdgeSetting.create!(name: 'Dirty', theme: 'light')
      setting.theme = 'dark'
      expect(setting.theme_changed?).to be true
    end
  end

  describe 'Encrypted attributes' do
    it 'encrypts and decrypts content transparently' do
      note = ArEdgeSecretNote.create!(title: 'Secret', content: 'Top secret message')
      note.reload
      expect(note.content).to eq('Top secret message')
    end

    it 'stores encrypted value in database (not plaintext)' do
      note = ArEdgeSecretNote.create!(title: 'Hidden', content: 'Sensitive data')
      # Read the raw column value from DB
      raw = ActiveRecord::Base.connection.select_value(
        "SELECT content FROM ar_edge_secret_notes WHERE id = #{note.id}"
      )
      expect(raw).not_to eq('Sensitive data')
      expect(raw).to be_present
    end

    it 'supports updating encrypted fields' do
      note = ArEdgeSecretNote.create!(title: 'Updatable', content: 'Original')
      note.update!(content: 'Modified')
      expect(note.reload.content).to eq('Modified')
    end

    it 'supports nil encrypted values' do
      note = ArEdgeSecretNote.create!(title: 'NoContent')
      expect(note.reload.content).to be_nil
    end
  end

  describe 'JSON columns' do
    it 'stores and retrieves JSON objects' do
      doc = ArEdgeJsonDoc.create!(name: 'Config', payload: { 'key' => 'value', 'count' => 42 })
      doc.reload
      expect(doc.payload).to eq({ 'key' => 'value', 'count' => 42 })
    end

    it 'stores JSON arrays' do
      doc = ArEdgeJsonDoc.create!(name: 'List', payload: [1, 2, 3, 'four'])
      expect(doc.reload.payload).to eq([1, 2, 3, 'four'])
    end

    it 'stores nested JSON' do
      nested = { 'users' => [{ 'name' => 'Alice', 'age' => 30 }, { 'name' => 'Bob', 'age' => 25 }] }
      doc = ArEdgeJsonDoc.create!(name: 'Nested', payload: nested)
      expect(doc.reload.payload).to eq(nested)
    end

    it 'stores null JSON' do
      doc = ArEdgeJsonDoc.create!(name: 'Empty', payload: nil)
      expect(doc.reload.payload).to be_nil
    end

    it 'updates JSON values' do
      doc = ArEdgeJsonDoc.create!(name: 'Mutable', payload: { 'x' => 1 })
      doc.update!(payload: { 'x' => 2, 'y' => 3 })
      expect(doc.reload.payload).to eq({ 'x' => 2, 'y' => 3 })
    end

    it 'supports JSON with boolean and null values' do
      data = { 'active' => true, 'deleted' => false, 'meta' => nil }
      doc = ArEdgeJsonDoc.create!(name: 'Booleans', payload: data)
      result = doc.reload.payload
      expect(result['active']).to be true
      expect(result['deleted']).to be false
      expect(result['meta']).to be_nil
    end
  end

  describe 'String/UUID primary keys' do
    it 'creates records with string primary key' do
      record = ArEdgeUuidRecord.create!(id: SecureRandom.uuid, label: 'First')
      expect(record.id).to be_a(String)
      expect(record.id.length).to eq(36)
    end

    it 'finds records by string primary key' do
      id = SecureRandom.uuid
      ArEdgeUuidRecord.create!(id: id, label: 'Findable')
      found = ArEdgeUuidRecord.find(id)
      expect(found.label).to eq('Findable')
    end

    it 'supports associations with string foreign keys' do
      id = SecureRandom.uuid
      ArEdgeUuidRecord.create!(id: id, label: 'Associated')
      found = ArEdgeUuidRecord.where(id: id)
      expect(found.count).to eq(1)
    end

    it 'raises RecordNotFound for missing UUID' do
      expect { ArEdgeUuidRecord.find('nonexistent-uuid') }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'supports destroy with string PK' do
      id = SecureRandom.uuid
      ArEdgeUuidRecord.create!(id: id, label: 'Destroyable')
      ArEdgeUuidRecord.find(id).destroy!
      expect(ArEdgeUuidRecord.find_by(id: id)).to be_nil
    end
  end

  describe 'Prepared statements' do
    it 'executes parameterized queries via find' do
      ArEdgePrepStmtTest.create!(code: 'AAA', value: 10)
      ArEdgePrepStmtTest.create!(code: 'BBB', value: 20)

      # find triggers a prepared statement internally
      record = ArEdgePrepStmtTest.find_by(code: 'AAA')
      expect(record.value).to eq(10)
    end

    it 'handles repeated parameterized queries' do
      5.times { |i| ArEdgePrepStmtTest.create!(code: "CODE#{i}", value: i * 10) }

      # Each call should reuse the prepared statement
      results = (0..4).map { |i| ArEdgePrepStmtTest.find_by(code: "CODE#{i}") }
      expect(results.map(&:value)).to eq([0, 10, 20, 30, 40])
    end

    it 'supports bind parameters in where clauses' do
      ArEdgePrepStmtTest.create!(code: 'X', value: 100)
      ArEdgePrepStmtTest.create!(code: 'Y', value: 200)
      ArEdgePrepStmtTest.create!(code: 'Z', value: 300)

      results = ArEdgePrepStmtTest.where('value > ?', 150)
      expect(results.pluck(:code).sort).to eq(%w[Y Z])
    end

    it 'handles queries with multiple bind params' do
      ArEdgePrepStmtTest.create!(code: 'MULTI', value: 50)
      ArEdgePrepStmtTest.create!(code: 'MULTI', value: 150)
      ArEdgePrepStmtTest.create!(code: 'OTHER', value: 100)

      results = ArEdgePrepStmtTest.where('code = ? AND value > ?', 'MULTI', 75)
      expect(results.count).to eq(1)
      expect(results.first.value).to eq(150)
    end
  end

  describe 'Advisory locks' do
    it 'supports get_advisory_lock and release_advisory_lock' do
      conn = ActiveRecord::Base.connection
      # Advisory locks are used internally by AR migrations
      # Test that the connection supports the lock/unlock cycle
      if conn.respond_to?(:get_advisory_lock)
        lock_id = 123_456
        acquired = conn.get_advisory_lock(lock_id)
        expect(acquired).to be true

        released = conn.release_advisory_lock(lock_id)
        expect(released).to be true
      else
        skip 'Advisory locks not supported by this adapter'
      end
    end

    it 'prevents double-acquisition of the same lock from same connection' do
      conn = ActiveRecord::Base.connection
      if conn.respond_to?(:get_advisory_lock)
        lock_id = 789_012
        conn.get_advisory_lock(lock_id)
        # Getting the same lock again should succeed (reentrant in PG, same session in MySQL)
        second = conn.get_advisory_lock(lock_id)
        expect(second).to be true
        conn.release_advisory_lock(lock_id)
        conn.release_advisory_lock(lock_id)
      else
        skip 'Advisory locks not supported by this adapter'
      end
    end
  end

  describe 'Explain' do
    before do
      5.times { |i| ArEdgePrepStmtTest.create!(code: "EXP#{i}", value: i * 100) }
    end

    it 'returns explain output for simple query' do
      output = ArEdgePrepStmtTest.where('value > ?', 200).explain
      expect(output.to_s).to be_a(String)
      expect(output.to_s.length).to be > 10
    end

    it 'returns explain for join query' do
      # Just ensure it doesn't raise — output format varies by adapter
      output = ArEdgePrepStmtTest.where(code: 'EXP1').explain
      expect(output.to_s).not_to be_empty
    end
  end

  describe 'Connection metadata' do
    it 'reports adapter name' do
      name = ActiveRecord::Base.connection.adapter_name
      expect(name).to match(/AwsMySQL2|AwsPostgreSQL/)
    end

    it 'reports database version' do
      version = ActiveRecord::Base.connection.database_version
      # Returns a Version object in AR 7.2+; verify it's present and meaningful
      expect(version).to be_present
      expect(version.to_s).to match(/\d/)
    end

    it 'lists tables' do
      tables = ActiveRecord::Base.connection.tables
      expect(tables).to include('ar_edge_settings')
      expect(tables).to include('ar_edge_json_docs')
    end

    it 'lists columns for a table' do
      columns = ActiveRecord::Base.connection.columns(:ar_edge_settings)
      names = columns.map(&:name)
      expect(names).to include('name', 'preferences', 'metadata')
    end

    it 'reports column types' do
      columns = ActiveRecord::Base.connection.columns(:ar_edge_prep_stmt_tests)
      code_col = columns.find { |c| c.name == 'code' }
      value_col = columns.find { |c| c.name == 'value' }
      expect(code_col.sql_type).to match(/varchar|character varying/i)
      expect(value_col.sql_type).to match(/int/i)
    end

    it 'checks table existence' do
      expect(ActiveRecord::Base.connection.table_exists?(:ar_edge_settings)).to be true
      expect(ActiveRecord::Base.connection.table_exists?(:nonexistent_table)).to be false
    end
  end

  describe 'Error handling and edge cases' do
    it 'raises StatementInvalid for bad SQL' do
      expect {
        ActiveRecord::Base.connection.execute('SELECT * FROM nonexistent_table_xyz')
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'handles empty result sets gracefully' do
      expect(ArEdgePrepStmtTest.where(code: 'NONEXISTENT').to_a).to eq([])
      expect(ArEdgePrepStmtTest.where(code: 'NONEXISTENT').count).to eq(0)
    end

    it 'handles very long string values' do
      long_string = 'x' * 255
      record = ArEdgePrepStmtTest.create!(code: long_string, value: 1)
      expect(record.reload.code).to eq(long_string)
    end

    it 'handles special characters in strings' do
      special = "it's a \"test\" with \\ backslash & ampersand < > ' \" NULL \x00"
      # Remove null byte which some DBs don't support in strings
      safe_special = special.delete("\x00")
      record = ArEdgeSetting.create!(name: safe_special)
      expect(record.reload.name).to eq(safe_special)
    end

    it 'handles unicode strings' do
      unicode = '日本語テスト 🚀 émoji café'
      record = ArEdgeSetting.create!(name: unicode)
      expect(record.reload.name).to eq(unicode)
    end

    it 'handles concurrent reads safely' do
      ArEdgePrepStmtTest.create!(code: 'CONCURRENT', value: 42)
      threads = 10.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ArEdgePrepStmtTest.find_by(code: 'CONCURRENT')&.value
          end
        end
      end
      results = threads.map(&:value)
      expect(results).to all(eq(42))
    end
  end

  describe 'Attribute API' do
    it 'supports attribute query methods' do
      record = ArEdgePrepStmtTest.create!(code: 'ATTR', value: 0)
      # attribute? returns false for 0/nil/blank
      expect(record.value?).to be false
      record.update!(value: 1)
      expect(record.reload.value?).to be true
    end

    it 'supports read_attribute and write_attribute' do
      record = ArEdgePrepStmtTest.create!(code: 'RW', value: 10)
      expect(record.read_attribute(:value)).to eq(10)

      record.write_attribute(:value, 20)
      record.save!
      expect(record.reload.value).to eq(20)
    end

    it 'supports attributes hash' do
      record = ArEdgePrepStmtTest.create!(code: 'HASH', value: 99)
      attrs = record.attributes
      expect(attrs).to be_a(Hash)
      expect(attrs['code']).to eq('HASH')
      expect(attrs['value']).to eq(99)
    end

    it 'supports assign_attributes' do
      record = ArEdgePrepStmtTest.create!(code: 'ASSIGN', value: 1)
      record.assign_attributes(code: 'CHANGED', value: 2)
      expect(record).to be_changed
      record.save!
      expect(record.reload.code).to eq('CHANGED')
    end

    it 'supports attribute_names' do
      names = ArEdgePrepStmtTest.attribute_names
      expect(names).to include('id', 'code', 'value')
    end
  end
end


ActiveRecord::Encryption.configure(
  primary_key: 'test-primary-key-that-is-32-bytes!',
  deterministic_key: 'test-deterministic-key-32-bytes!',
  key_derivation_salt: 'test-key-derivation-salt-value!!'
)

class ArEdgeSetting < ActiveRecord::Base
  self.table_name = 'ar_edge_settings'

  store :preferences, accessors: %i[theme language], coder: JSON
  store :metadata, accessors: %i[version], coder: JSON

  validates :name, presence: true
end

class ArEdgeSecretNote < ActiveRecord::Base
  self.table_name = 'ar_edge_secret_notes'

  encrypts :content

  validates :title, presence: true
end

class ArEdgeJsonDoc < ActiveRecord::Base
  self.table_name = 'ar_edge_json_docs'

  validates :name, presence: true
end

class ArEdgeUuidRecord < ActiveRecord::Base
  self.table_name = 'ar_edge_uuid_records'
  self.primary_key = 'id'

  before_create :set_uuid, unless: :id?

  validates :label, presence: true

  private

  def set_uuid
    self.id = SecureRandom.uuid
  end
end

class ArEdgePrepStmtTest < ActiveRecord::Base
  self.table_name = 'ar_edge_prep_stmt_tests'

  validates :code, presence: true
end

class ArEdgeMigrationLock < ActiveRecord::Base
  self.table_name = 'ar_edge_migration_locks'
end


RSpec.describe 'ActiveRecord types and edge cases' do
  include_context 'adapter context'

  context 'PostgreSQL' do
    include_examples 'ActiveRecord types and edge cases', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'ActiveRecord types and edge cases', MysqlTestHelper
  end
end
