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

RSpec.shared_examples 'ActiveRecord querying and relations' do |driver_helper|
  include driver_helper

  QUERY_MODELS = [ArQueryAccount, ArQueryTransaction, ArQueryProfile, ArQueryEvent, ArQueryWidget].freeze unless defined?(QUERY_MODELS)

  before(:all) do
    ActiveRecordAdapterHelper.establish_fresh_connection(driver_helper, QUERY_MODELS)

    ActiveRecord::Schema.define do
      suppress_messages do
        create_table :ar_query_accounts, force: true do |t|
          t.string :name, null: false
          t.text :settings
          t.date :started_on
          t.datetime :last_login_at
          t.boolean :verified, default: false
          t.decimal :balance, precision: 12, scale: 2, default: 0.0
          t.timestamps
        end

        create_table :ar_query_transactions, force: true do |t|
          t.references :ar_query_account, foreign_key: true, null: false
          t.decimal :amount, precision: 10, scale: 2, null: false
          t.string :category
          t.string :status, default: 'pending'
          t.datetime :processed_at
          t.timestamps
        end

        create_table :ar_query_profiles, force: true do |t|
          t.references :ar_query_account, foreign_key: true, null: false
          t.string :bio
          t.string :avatar_url
          t.timestamps
        end

        create_table :ar_query_events, force: true do |t|
          t.string :name, null: false
          t.string :event_type
          t.datetime :occurred_at
          t.timestamps
        end

        create_table :ar_query_widgets, force: true do |t|
          t.string :name, null: false
          t.text :config
          t.timestamps
        end
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      suppress_messages do
        drop_table :ar_query_profiles, if_exists: true
        drop_table :ar_query_transactions, if_exists: true
        drop_table :ar_query_accounts, if_exists: true
        drop_table :ar_query_events, if_exists: true
        drop_table :ar_query_widgets, if_exists: true
      end
    end
    ActiveRecord::Base.connection_handler.clear_active_connections!
  end

  before do
    ArQueryProfile.delete_all
    ArQueryTransaction.delete_all
    ArQueryAccount.delete_all
    ArQueryEvent.delete_all
    ArQueryWidget.delete_all
  end

  describe 'Type casting and serialization' do
    it 'handles date columns correctly' do
      date = Date.new(2024, 6, 15)
      account = ArQueryAccount.create!(name: 'DateTest', started_on: date)
      expect(account.reload.started_on).to eq(date)
      expect(account.started_on).to be_a(Date)
    end

    it 'handles datetime columns correctly' do
      time = Time.new(2024, 3, 15, 10, 30, 0, '+00:00')
      account = ArQueryAccount.create!(name: 'TimeTest', last_login_at: time)
      expect(account.reload.last_login_at).to be_within(1).of(time)
    end

    it 'handles boolean coercion' do
      account = ArQueryAccount.create!(name: 'BoolTest', verified: true)
      expect(account.reload.verified).to be true

      account.update!(verified: false)
      expect(account.reload.verified).to be false
    end

    it 'handles decimal precision' do
      account = ArQueryAccount.create!(name: 'DecimalTest', balance: 12_345.67)
      expect(account.reload.balance).to eq(BigDecimal('12345.67'))
    end

    it 'handles nil values for nullable columns' do
      account = ArQueryAccount.create!(name: 'NilTest')
      account.reload
      expect(account.started_on).to be_nil
      expect(account.last_login_at).to be_nil
      expect(account.settings).to be_nil
    end

    it 'serializes and deserializes JSON in text column' do
      settings = { 'theme' => 'dark', 'notifications' => true, 'limit' => 50 }
      account = ArQueryAccount.create!(name: 'JsonTest', settings: settings)
      expect(account.reload.settings).to eq(settings)
    end

    it 'handles string-to-date coercion on assignment' do
      account = ArQueryAccount.create!(name: 'CoerceTest', started_on: '2024-01-15')
      expect(account.reload.started_on).to eq(Date.new(2024, 1, 15))
    end
  end

  describe 'Relation caching and reload' do
    before do
      @account = ArQueryAccount.create!(name: 'RelTest', balance: 100.00)
      3.times { |i| ArQueryTransaction.create!(ar_query_account: @account, amount: (i + 1) * 10, category: 'food') }
    end

    it 'caches relation results until reload' do
      relation = ArQueryTransaction.where(ar_query_account: @account)
      initial_count = relation.count

      ArQueryTransaction.create!(ar_query_account: @account, amount: 99, category: 'new')
      # The relation object re-queries by default in AR (no caching for count)
      expect(relation.count).to eq(initial_count + 1)
    end

    it 'supports reload on association' do
      transactions = @account.ar_query_transactions.to_a
      expect(transactions.size).to eq(3)

      ArQueryTransaction.create!(ar_query_account: @account, amount: 50, category: 'extra')
      expect(@account.ar_query_transactions.reload.size).to eq(4)
    end

    it 'supports reset on relation' do
      relation = ArQueryTransaction.where(ar_query_account: @account)
      relation.to_a # force load
      expect(relation).to be_loaded

      relation.reset
      expect(relation).not_to be_loaded
    end

    it 'to_a materializes the relation' do
      relation = ArQueryTransaction.where(ar_query_account: @account)
      array = relation.to_a
      expect(array).to be_an(Array)
      expect(array.size).to eq(3)
      expect(array.first).to be_a(ArQueryTransaction)
    end
  end

  describe 'Calculation queries' do
    before do
      account = ArQueryAccount.create!(name: 'CalcTest', balance: 500.00)
      ArQueryTransaction.create!(ar_query_account: account, amount: 100, category: 'food')
      ArQueryTransaction.create!(ar_query_account: account, amount: 200, category: 'food')
      ArQueryTransaction.create!(ar_query_account: account, amount: 50, category: 'transport')
      ArQueryTransaction.create!(ar_query_account: account, amount: 75, category: 'transport')
      ArQueryTransaction.create!(ar_query_account: account, amount: 300, category: 'entertainment')
    end

    it 'supports group with sum' do
      result = ArQueryTransaction.group(:category).sum(:amount)
      expect(result['food'].to_f).to eq(300.0)
      expect(result['transport'].to_f).to eq(125.0)
      expect(result['entertainment'].to_f).to eq(300.0)
    end

    it 'supports group with average' do
      result = ArQueryTransaction.group(:category).average(:amount)
      expect(result['food'].to_f).to eq(150.0)
      expect(result['transport'].to_f).to eq(62.5)
    end

    it 'supports group with count' do
      result = ArQueryTransaction.group(:category).count
      expect(result['food']).to eq(2)
      expect(result['transport']).to eq(2)
      expect(result['entertainment']).to eq(1)
    end

    it 'supports count with distinct' do
      distinct_count = ArQueryTransaction.distinct.count(:category)
      expect(distinct_count).to eq(3)
    end

    it 'supports group with minimum and maximum' do
      min = ArQueryTransaction.group(:category).minimum(:amount)
      max = ArQueryTransaction.group(:category).maximum(:amount)
      expect(min['food'].to_f).to eq(100.0)
      expect(max['food'].to_f).to eq(200.0)
    end

    it 'supports calculation with conditions' do
      total = ArQueryTransaction.where(category: 'food').sum(:amount)
      expect(total.to_f).to eq(300.0)
    end
  end

  describe 'Subqueries' do
    before do
      @rich = ArQueryAccount.create!(name: 'Rich', balance: 10_000)
      @poor = ArQueryAccount.create!(name: 'Poor', balance: 100)
      ArQueryTransaction.create!(ar_query_account: @rich, amount: 500, category: 'luxury')
      ArQueryTransaction.create!(ar_query_account: @poor, amount: 10, category: 'food')
    end

    it 'supports where with subquery' do
      high_balance_ids = ArQueryAccount.where('balance > ?', 1000).select(:id)
      transactions = ArQueryTransaction.where(ar_query_account_id: high_balance_ids)
      expect(transactions.count).to eq(1)
      expect(transactions.first.category).to eq('luxury')
    end

    it 'supports NOT IN subquery' do
      low_balance_ids = ArQueryAccount.where('balance < ?', 1000).select(:id)
      transactions = ArQueryTransaction.where.not(ar_query_account_id: low_balance_ids)
      expect(transactions.count).to eq(1)
      expect(transactions.first.amount.to_f).to eq(500.0)
    end

    it 'supports exists with subquery' do
      has_transactions = ArQueryAccount.where(
        'EXISTS (SELECT 1 FROM ar_query_transactions WHERE ar_query_transactions.ar_query_account_id = ar_query_accounts.id)'
      )
      expect(has_transactions.count).to eq(2)
    end

    it 'supports subquery in select' do
      result = ArQueryAccount.select(
        'ar_query_accounts.name',
        '(SELECT COUNT(*) FROM ar_query_transactions WHERE ar_query_transactions.ar_query_account_id = ar_query_accounts.id) as tx_count'
      ).order(:name)
      expect(result.first.name).to eq('Poor')
      expect(result.first.tx_count.to_i).to eq(1)
    end
  end

  describe 'OR queries' do
    before do
      ArQueryAccount.create!(name: 'Alice', balance: 500, verified: true)
      ArQueryAccount.create!(name: 'Bob', balance: 1500, verified: false)
      ArQueryAccount.create!(name: 'Carol', balance: 200, verified: false)
    end

    it 'supports basic or' do
      results = ArQueryAccount.where(verified: true).or(ArQueryAccount.where('balance > ?', 1000))
      expect(results.pluck(:name).sort).to eq(%w[Alice Bob])
    end

    it 'supports or with multiple conditions' do
      results = ArQueryAccount.where(name: 'Alice').or(ArQueryAccount.where(name: 'Carol'))
      expect(results.count).to eq(2)
    end

    it 'supports or chained with other scopes' do
      results = ArQueryAccount.where(verified: true)
                              .or(ArQueryAccount.where('balance > ?', 1000))
                              .order(:name)
      expect(results.pluck(:name)).to eq(%w[Alice Bob])
    end
  end

  describe 'Strict loading' do
    before do
      account = ArQueryAccount.create!(name: 'StrictTest', balance: 1000)
      ArQueryProfile.create!(ar_query_account: account, bio: 'Hello')
      ArQueryTransaction.create!(ar_query_account: account, amount: 50, category: 'test')
    end

    it 'raises on lazy load when strict_loading is enabled' do
      account = ArQueryAccount.strict_loading.first
      expect { account.ar_query_transactions.to_a }.to raise_error(ActiveRecord::StrictLoadingViolationError)
    end

    it 'allows access when eager loaded with strict_loading' do
      account = ArQueryAccount.includes(:ar_query_transactions).strict_loading.first
      expect { account.ar_query_transactions.to_a }.not_to raise_error
      expect(account.ar_query_transactions.size).to eq(1)
    end

    it 'supports strict_loading on individual records' do
      account = ArQueryAccount.first
      account.strict_loading!
      expect { account.ar_query_profile }.to raise_error(ActiveRecord::StrictLoadingViolationError)
    end
  end

  describe 'find_in_batches' do
    before do
      15.times { |i| ArQueryEvent.create!(name: "Event #{i}", event_type: 'click', occurred_at: Time.now - (i * 3600)) }
    end

    it 'processes records in batches' do
      batches = []
      ArQueryEvent.find_in_batches(batch_size: 5) { |batch| batches << batch.size }
      expect(batches).to eq([5, 5, 5])
    end

    it 'supports find_in_batches with conditions' do
      ArQueryEvent.create!(name: 'Special', event_type: 'purchase', occurred_at: Time.now)
      batches = []
      ArQueryEvent.where(event_type: 'click').find_in_batches(batch_size: 10) { |batch| batches << batch.size }
      expect(batches).to eq([10, 5])
    end

    it 'supports find_each with batch_size' do
      names = []
      ArQueryEvent.order(:id).find_each(batch_size: 4) { |event| names << event.name }
      expect(names.size).to eq(15)
    end

    it 'supports in_batches yielding relations' do
      total = 0
      ArQueryEvent.in_batches(of: 7) do |batch|
        expect(batch).to be_a(ActiveRecord::Relation)
        total += batch.count
      end
      expect(total).to eq(15)
    end

    it 'supports in_batches with update_all' do
      ArQueryEvent.in_batches(of: 5).update_all(event_type: 'archived')
      expect(ArQueryEvent.where(event_type: 'archived').count).to eq(15)
    end
  end

  describe 'Database views' do
    before do
      account = ArQueryAccount.create!(name: 'ViewTest', balance: 1000, verified: true)
      ArQueryTransaction.create!(ar_query_account: account, amount: 100, category: 'food', status: 'completed')
      ArQueryTransaction.create!(ar_query_account: account, amount: 200, category: 'food', status: 'completed')
      ArQueryTransaction.create!(ar_query_account: account, amount: 50, category: 'transport', status: 'pending')

      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE OR REPLACE VIEW ar_query_completed_transactions_view AS
        SELECT ar_query_transactions.* FROM ar_query_transactions WHERE status = 'completed'
      SQL
    end

    after do
      ActiveRecord::Base.connection.execute('DROP VIEW IF EXISTS ar_query_completed_transactions_view')
    end

    it 'reads from a database view via a model' do
      # Define a model backed by the view
      expect(ArQueryCompletedTransaction.count).to eq(2)
      expect(ArQueryCompletedTransaction.sum(:amount).to_f).to eq(300.0)
    end

    it 'supports querying the view with conditions' do
      results = ArQueryCompletedTransaction.where(category: 'food')
      expect(results.count).to eq(2)
    end
  end

  describe 'ActiveRecord::Store' do
    it 'reads and writes store accessors' do
      widget = ArQueryWidget.create!(name: 'MyWidget', color: 'blue', size: 'large')
      widget.reload
      expect(widget.color).to eq('blue')
      expect(widget.size).to eq('large')
    end

    it 'updates individual store keys' do
      widget = ArQueryWidget.create!(name: 'W2', color: 'red', size: 'small')
      widget.update!(color: 'green')
      expect(widget.reload.color).to eq('green')
      expect(widget.size).to eq('small')
    end

    it 'handles nil store values' do
      widget = ArQueryWidget.create!(name: 'W3')
      expect(widget.color).to be_nil
      expect(widget.size).to be_nil
    end

    it 'supports querying raw config column' do
      ArQueryWidget.create!(name: 'W4', color: 'purple', size: 'medium')
      widget = ArQueryWidget.find_by(name: 'W4')
      # The raw config column contains serialized YAML/JSON
      expect(widget.config).to be_present
    end
  end

  describe 'Explain' do
    before do
      ArQueryAccount.create!(name: 'ExplainTest', balance: 500)
    end

    it 'returns a query plan for a relation' do
      explanation = ArQueryAccount.where(name: 'ExplainTest').explain
      # Both PG and MySQL return a string describing the execution plan
      expect(explanation.to_s).to be_a(String)
      expect(explanation.to_s.length).to be > 0
    end
  end

  describe 'Advanced query methods' do
    before do
      ArQueryAccount.create!(name: 'Alice', balance: 100, verified: true)
      ArQueryAccount.create!(name: 'Bob', balance: 200, verified: false)
      ArQueryAccount.create!(name: 'Carol', balance: 300, verified: true)
    end

    it 'supports ids' do
      ids = ArQueryAccount.where(verified: true).ids
      expect(ids.size).to eq(2)
      expect(ids).to all(be_a(Integer))
    end

    it 'supports pick (single row pluck)' do
      name = ArQueryAccount.order(:balance).pick(:name)
      expect(name).to eq('Alice')
    end

    it 'supports pick with multiple columns' do
      result = ArQueryAccount.order(:balance).pick(:name, :balance)
      expect(result).to eq(['Alice', BigDecimal('100')])
    end

    it 'supports pluck with SQL expression' do
      totals = ArQueryAccount.pluck(Arel.sql('SUM(balance)'))
      expect(totals.first.to_f).to eq(600.0)
    end

    it 'supports where with range' do
      results = ArQueryAccount.where(balance: 100..250)
      expect(results.pluck(:name).sort).to eq(%w[Alice Bob])
    end

    it 'supports where with array' do
      results = ArQueryAccount.where(name: %w[Alice Carol])
      expect(results.count).to eq(2)
    end
  end

  describe 'Complex joins and includes' do
    before do
      @a1 = ArQueryAccount.create!(name: 'Joiner', balance: 1000, verified: true)
      @a2 = ArQueryAccount.create!(name: 'NoTx', balance: 500, verified: true)
      ArQueryTransaction.create!(ar_query_account: @a1, amount: 100, category: 'food', status: 'completed')
      ArQueryTransaction.create!(ar_query_account: @a1, amount: 200, category: 'luxury', status: 'pending')
      ArQueryProfile.create!(ar_query_account: @a1, bio: 'I am joiner')
    end

    it 'supports left_joins' do
      results = ArQueryAccount.left_joins(:ar_query_transactions).distinct
      expect(results.count).to eq(2)
    end

    it 'supports joins with where on associated table' do
      results = ArQueryAccount.joins(:ar_query_transactions)
                              .where(ar_query_transactions: { status: 'completed' })
      expect(results.first.name).to eq('Joiner')
    end

    it 'supports includes with nested associations' do
      accounts = ArQueryAccount.includes(:ar_query_profile, :ar_query_transactions).where(name: 'Joiner')
      account = accounts.first
      expect(account.ar_query_profile.bio).to eq('I am joiner')
      expect(account.ar_query_transactions.size).to eq(2)
    end

    it 'supports merge for combining scopes across models' do
      completed = ArQueryTransaction.where(status: 'completed')
      accounts = ArQueryAccount.joins(:ar_query_transactions).merge(completed)
      expect(accounts.distinct.pluck(:name)).to eq(['Joiner'])
    end
  end

  describe 'Scoping' do
    before do
      @a1 = ArQueryAccount.create!(name: 'Active1', balance: 100, verified: true)
      @a2 = ArQueryAccount.create!(name: 'Active2', balance: 200, verified: true)
      @a3 = ArQueryAccount.create!(name: 'Inactive', balance: 50, verified: false)
      ArQueryTransaction.create!(ar_query_account: @a1, amount: 30, category: 'food', status: 'completed')
      ArQueryTransaction.create!(ar_query_account: @a1, amount: 40, category: 'food', status: 'pending')
    end

    it 'supports named scopes' do
      expect(ArQueryAccount.verified.count).to eq(2)
      expect(ArQueryAccount.high_balance.count).to eq(1)
    end

    it 'supports scope chaining' do
      expect(ArQueryAccount.verified.high_balance.count).to eq(1)
      expect(ArQueryAccount.verified.high_balance.first.name).to eq('Active2')
    end

    it 'supports scoping block' do
      ArQueryAccount.where(verified: true).scoping do
        expect(ArQueryAccount.count).to eq(2)
      end
    end

    it 'supports transaction scopes' do
      expect(ArQueryTransaction.completed.count).to eq(1)
      expect(ArQueryTransaction.pending_status.count).to eq(1)
    end
  end
end

class ArQueryAccount < ActiveRecord::Base
  self.table_name = 'ar_query_accounts'

  has_many :ar_query_transactions, dependent: :destroy
  has_one :ar_query_profile, dependent: :destroy

  serialize :settings, coder: JSON

  scope :verified, -> { where(verified: true) }
  scope :high_balance, -> { where('balance >= ?', 200) }

  validates :name, presence: true
end

class ArQueryTransaction < ActiveRecord::Base
  self.table_name = 'ar_query_transactions'

  belongs_to :ar_query_account

  scope :completed, -> { where(status: 'completed') }
  scope :pending_status, -> { where(status: 'pending') }

  validates :amount, presence: true
end

class ArQueryProfile < ActiveRecord::Base
  self.table_name = 'ar_query_profiles'

  belongs_to :ar_query_account
end

class ArQueryEvent < ActiveRecord::Base
  self.table_name = 'ar_query_events'

  validates :name, presence: true
end

class ArQueryWidget < ActiveRecord::Base
  self.table_name = 'ar_query_widgets'

  store :config, accessors: %i[color size], coder: JSON

  validates :name, presence: true
end

class ArQueryCompletedTransaction < ActiveRecord::Base
  self.table_name = 'ar_query_completed_transactions_view'
end

RSpec.describe 'ActiveRecord querying and relations' do
  include_context 'adapter context'

  context 'PostgreSQL' do
    include_examples 'ActiveRecord querying and relations', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'ActiveRecord querying and relations', MysqlTestHelper
  end
end
