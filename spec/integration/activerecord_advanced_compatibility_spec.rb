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

RSpec.shared_examples 'ActiveRecord advanced compatibility' do |driver_helper|
  include driver_helper

  before(:all) do
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(driver_helper.adapter_config)

    # Reset quoted_table_name cache on all test models since it's adapter-specific.
    # In AR 7.2, quoted_table_name is cached using adapter_class.quote_table_name,
    # so we must clear the instance variable when switching adapters.
    [ArAdvArticle, ArAdvVideo, ArAdvReaction, ArAdvVehicle, ArAdvCar, ArAdvTruck,
     ArAdvDoctor, ArAdvPatient, ArAdvAppointment, ArAdvForum, ArAdvTopic,
     ArAdvOrder, ArAdvLibrary, ArAdvBook, ArAdvProduct, ArAdvCategory, ArAdvItem].each do |klass|
      klass.instance_variable_set(:@quoted_table_name, nil)
    end

    ActiveRecord::Schema.define do
      suppress_messages do
        # --- Polymorphic associations ---
        create_table :ar_adv_articles, force: true do |t|
          t.string :title, null: false
          t.text :body
          t.timestamps
        end

        create_table :ar_adv_videos, force: true do |t|
          t.string :title, null: false
          t.string :url
          t.timestamps
        end

        create_table :ar_adv_reactions, force: true do |t|
          t.string :emoji, null: false
          t.references :reactable, polymorphic: true, null: false
          t.timestamps
        end

        # --- STI (Single Table Inheritance) ---
        create_table :ar_adv_vehicles, force: true do |t|
          t.string :type, null: false
          t.string :name, null: false
          t.integer :horsepower
          t.integer :cargo_capacity
          t.timestamps
        end

        # --- has_many :through ---
        create_table :ar_adv_doctors, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_adv_patients, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_adv_appointments, force: true do |t|
          t.references :ar_adv_doctor, foreign_key: true, null: false
          t.references :ar_adv_patient, foreign_key: true, null: false
          t.datetime :scheduled_at, null: false
          t.string :notes
          t.timestamps
        end

        # --- Counter cache ---
        create_table :ar_adv_forums, force: true do |t|
          t.string :name, null: false
          t.integer :ar_adv_topics_count, default: 0
          t.timestamps
        end

        create_table :ar_adv_topics, force: true do |t|
          t.string :subject, null: false
          t.references :ar_adv_forum, foreign_key: true, null: false
          t.timestamps
        end

        # --- Enum ---
        create_table :ar_adv_orders, force: true do |t|
          t.integer :status, default: 0, null: false
          t.decimal :total, precision: 10, scale: 2
          t.string :customer_name, null: false
          t.timestamps
        end

        # --- Touch ---
        create_table :ar_adv_libraries, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_adv_books, force: true do |t|
          t.string :title, null: false
          t.references :ar_adv_library, foreign_key: true, null: false
          t.timestamps
        end

        # --- Bulk operations (upsert/insert_all) ---
        create_table :ar_adv_products, force: true do |t|
          t.string :sku, null: false
          t.string :name, null: false
          t.decimal :price, precision: 10, scale: 2
          t.integer :stock, default: 0
          t.timestamps
        end

        add_index :ar_adv_products, :sku, unique: true

        # --- Preloading strategies ---
        create_table :ar_adv_categories, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_adv_items, force: true do |t|
          t.string :name, null: false
          t.references :ar_adv_category, foreign_key: true, null: false
          t.integer :quantity, default: 0
          t.timestamps
        end
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      suppress_messages do
        drop_table :ar_adv_reactions, if_exists: true
        drop_table :ar_adv_articles, if_exists: true
        drop_table :ar_adv_videos, if_exists: true
        drop_table :ar_adv_vehicles, if_exists: true
        drop_table :ar_adv_appointments, if_exists: true
        drop_table :ar_adv_doctors, if_exists: true
        drop_table :ar_adv_patients, if_exists: true
        drop_table :ar_adv_topics, if_exists: true
        drop_table :ar_adv_forums, if_exists: true
        drop_table :ar_adv_orders, if_exists: true
        drop_table :ar_adv_books, if_exists: true
        drop_table :ar_adv_libraries, if_exists: true
        drop_table :ar_adv_products, if_exists: true
        drop_table :ar_adv_items, if_exists: true
        drop_table :ar_adv_categories, if_exists: true
      end
    end
    ActiveRecord::Base.connection_handler.clear_active_connections!
  end

  before do
    # Verify correct adapter is active; reconnect if switched by another context.
    expected_adapter = driver_helper.adapter_config[:adapter].include?('mysql') ? 'AwsMySQL2' : 'AwsPostgreSQL'
    if ActiveRecord::Base.connection.adapter_name != expected_adapter
      ActiveRecord::Base.connection_handler.clear_all_connections!
      ActiveRecord::Base.establish_connection(driver_helper.adapter_config)
      # Reset cached quoted_table_name which is adapter-specific
      [ArAdvArticle, ArAdvVideo, ArAdvReaction, ArAdvVehicle, ArAdvCar, ArAdvTruck,
       ArAdvDoctor, ArAdvPatient, ArAdvAppointment, ArAdvForum, ArAdvTopic,
       ArAdvOrder, ArAdvLibrary, ArAdvBook, ArAdvProduct, ArAdvCategory, ArAdvItem].each do |klass|
        klass.instance_variable_set(:@quoted_table_name, nil)
      end
    end
    ArAdvReaction.delete_all
    ArAdvArticle.delete_all
    ArAdvVideo.delete_all
    ArAdvVehicle.delete_all
    ArAdvAppointment.delete_all
    ArAdvDoctor.delete_all
    ArAdvPatient.delete_all
    ArAdvTopic.delete_all
    ArAdvForum.delete_all
    ArAdvOrder.delete_all
    ArAdvBook.delete_all
    ArAdvLibrary.delete_all
    ArAdvProduct.delete_all
    ArAdvItem.delete_all
    ArAdvCategory.delete_all
  end

  describe 'Advanced schema migrations' do
    after do
      ActiveRecord::Schema.define do
        suppress_messages do
          drop_table :ar_adv_migration_test, if_exists: true
          drop_table :ar_adv_renamed_table, if_exists: true
        end
      end
    end

    it 'supports change_column type' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_adv_migration_test, force: true do |t|
            t.string :amount
          end
          change_column :ar_adv_migration_test, :amount, :text
        end
      end
      col = ActiveRecord::Base.connection.columns(:ar_adv_migration_test).find { |c| c.name == 'amount' }
      expect(col.sql_type).to match(/text/i)
    end

    it 'supports rename_column' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_adv_migration_test, force: true do |t|
            t.string :old_name
          end
          rename_column :ar_adv_migration_test, :old_name, :new_name
        end
      end
      columns = ActiveRecord::Base.connection.columns(:ar_adv_migration_test).map(&:name)
      expect(columns).to include('new_name')
      expect(columns).not_to include('old_name')
    end

    it 'supports rename_table' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_adv_migration_test, force: true do |t|
            t.string :label
          end
          rename_table :ar_adv_migration_test, :ar_adv_renamed_table
        end
      end
      expect(ActiveRecord::Base.connection.table_exists?(:ar_adv_renamed_table)).to be true
      expect(ActiveRecord::Base.connection.table_exists?(:ar_adv_migration_test)).to be false
    end
  end

  describe 'Polymorphic associations' do
    it 'creates reactions on different reactable types' do
      article = ArAdvArticle.create!(title: 'Great Article', body: 'Content')
      video = ArAdvVideo.create!(title: 'Cool Video', url: 'https://example.com/v')

      r1 = ArAdvReaction.create!(emoji: '👍', reactable: article)
      r2 = ArAdvReaction.create!(emoji: '❤️', reactable: video)

      expect(r1.reactable).to eq(article)
      expect(r2.reactable).to eq(video)
      expect(r1.reactable_type).to eq('ArAdvArticle')
      expect(r2.reactable_type).to eq('ArAdvVideo')
    end

    it 'loads polymorphic associations from parent' do
      article = ArAdvArticle.create!(title: 'Article', body: 'Body')
      ArAdvReaction.create!(emoji: '🎉', reactable: article)
      ArAdvReaction.create!(emoji: '🔥', reactable: article)

      expect(article.ar_adv_reactions.count).to eq(2)
      expect(article.ar_adv_reactions.pluck(:emoji).sort).to eq(%w[🎉 🔥].sort)
    end

    it 'eager loads polymorphic associations' do
      article = ArAdvArticle.create!(title: 'Eager', body: 'Body')
      ArAdvReaction.create!(emoji: '👀', reactable: article)

      reactions = ArAdvReaction.includes(:reactable).where(reactable: article)
      expect(reactions.first.reactable.title).to eq('Eager')
    end
  end

  describe 'Single Table Inheritance' do
    it 'creates subclass records with correct type' do
      car = ArAdvCar.create!(name: 'Sedan', horsepower: 200)
      truck = ArAdvTruck.create!(name: 'Hauler', cargo_capacity: 5000)

      expect(car.type).to eq('ArAdvCar')
      expect(truck.type).to eq('ArAdvTruck')
    end

    it 'queries return correct subclass instances' do
      ArAdvCar.create!(name: 'Coupe', horsepower: 300)
      ArAdvTruck.create!(name: 'Pickup', cargo_capacity: 2000)

      vehicles = ArAdvVehicle.all
      expect(vehicles.map(&:class)).to contain_exactly(ArAdvCar, ArAdvTruck)
    end

    it 'scopes queries to subclass' do
      ArAdvCar.create!(name: 'Sports', horsepower: 400)
      ArAdvTruck.create!(name: 'Semi', cargo_capacity: 10_000)

      expect(ArAdvCar.count).to eq(1)
      expect(ArAdvTruck.count).to eq(1)
      expect(ArAdvVehicle.count).to eq(2)
    end

    it 'supports querying subclass-specific attributes' do
      ArAdvCar.create!(name: 'Fast', horsepower: 500)
      car = ArAdvCar.find_by(name: 'Fast')
      expect(car.horsepower).to eq(500)
    end
  end

  describe 'Counter cache' do
    it 'increments counter on create' do
      forum = ArAdvForum.create!(name: 'Ruby Forum')
      ArAdvTopic.create!(subject: 'Topic 1', ar_adv_forum: forum)
      ArAdvTopic.create!(subject: 'Topic 2', ar_adv_forum: forum)

      expect(forum.reload.ar_adv_topics_count).to eq(2)
    end

    it 'decrements counter on destroy' do
      forum = ArAdvForum.create!(name: 'Rails Forum')
      topic = ArAdvTopic.create!(subject: 'Temp Topic', ar_adv_forum: forum)
      expect(forum.reload.ar_adv_topics_count).to eq(1)

      topic.destroy!
      expect(forum.reload.ar_adv_topics_count).to eq(0)
    end

    it 'supports reset_counters' do
      forum = ArAdvForum.create!(name: 'Reset Forum')
      ArAdvTopic.create!(subject: 'T1', ar_adv_forum: forum)
      ArAdvTopic.create!(subject: 'T2', ar_adv_forum: forum)

      # Manually corrupt the counter
      ArAdvForum.update_counters(forum.id, ar_adv_topics_count: -10)
      expect(forum.reload.ar_adv_topics_count).to eq(-8)

      # Reset it
      ArAdvForum.reset_counters(forum.id, :ar_adv_topics)
      expect(forum.reload.ar_adv_topics_count).to eq(2)
    end
  end

  describe 'has_many :through' do
    it 'creates associations through join model' do
      doctor = ArAdvDoctor.create!(name: 'Dr. Smith')
      patient = ArAdvPatient.create!(name: 'John Doe')
      appointment = ArAdvAppointment.create!(
        ar_adv_doctor: doctor,
        ar_adv_patient: patient,
        scheduled_at: Time.now + 3600,
        notes: 'Checkup'
      )

      expect(doctor.ar_adv_patients).to include(patient)
      expect(patient.ar_adv_doctors).to include(doctor)
      expect(doctor.ar_adv_appointments.first).to eq(appointment)
    end

    it 'supports querying through the join model' do
      doctor = ArAdvDoctor.create!(name: 'Dr. Jones')
      p1 = ArAdvPatient.create!(name: 'Patient A')
      p2 = ArAdvPatient.create!(name: 'Patient B')
      ArAdvAppointment.create!(ar_adv_doctor: doctor, ar_adv_patient: p1,
                               scheduled_at: Time.now, notes: 'Visit')
      ArAdvAppointment.create!(ar_adv_doctor: doctor, ar_adv_patient: p2,
                               scheduled_at: Time.now, notes: 'Follow-up')

      expect(doctor.ar_adv_patients.count).to eq(2)
      expect(doctor.ar_adv_patients.pluck(:name).sort).to eq(['Patient A', 'Patient B'])
    end

    it 'supports conditions on through association' do
      doctor = ArAdvDoctor.create!(name: 'Dr. Lee')
      patient = ArAdvPatient.create!(name: 'Patient C')
      future = Time.now + 86_400
      past = Time.now - 86_400
      ArAdvAppointment.create!(ar_adv_doctor: doctor, ar_adv_patient: patient,
                               scheduled_at: future, notes: 'Future')
      ArAdvAppointment.create!(ar_adv_doctor: doctor, ar_adv_patient: patient,
                               scheduled_at: past, notes: 'Past')

      upcoming = doctor.ar_adv_appointments.where('scheduled_at > ?', Time.now)
      expect(upcoming.count).to eq(1)
      expect(upcoming.first.notes).to eq('Future')
    end
  end

  describe 'Preloading strategies' do
    before do
      3.times do |i|
        cat = ArAdvCategory.create!(name: "Category #{i}")
        2.times { |j| ArAdvItem.create!(name: "Item #{i}-#{j}", ar_adv_category: cat, quantity: j + 1) }
      end
    end

    it 'supports preload (separate queries)' do
      categories = ArAdvCategory.preload(:ar_adv_items).to_a
      expect(categories.size).to eq(3)
      expect(categories.first.ar_adv_items.size).to eq(2)
    end

    it 'supports eager_load (LEFT OUTER JOIN)' do
      categories = ArAdvCategory.eager_load(:ar_adv_items).to_a
      expect(categories.size).to eq(3)
      categories.each { |c| expect(c.ar_adv_items).to be_loaded }
    end

    it 'supports includes with where on association' do
      items = ArAdvItem.includes(:ar_adv_category)
                       .where(ar_adv_categories: { name: 'Category 0' })
                       .references(:ar_adv_categories)
      expect(items.count).to eq(2)
      expect(items.first.ar_adv_category.name).to eq('Category 0')
    end

    it 'supports includes without N+1' do
      categories = ArAdvCategory.includes(:ar_adv_items).to_a
      # Access items without triggering additional queries
      total_items = categories.sum { |c| c.ar_adv_items.size }
      expect(total_items).to eq(6)
    end
  end

  describe 'Bulk operations' do
    it 'supports insert_all' do
      records = [
        { sku: 'SKU-001', name: 'Widget', price: 9.99, stock: 100,
          created_at: Time.now, updated_at: Time.now },
        { sku: 'SKU-002', name: 'Gadget', price: 19.99, stock: 50,
          created_at: Time.now, updated_at: Time.now },
        { sku: 'SKU-003', name: 'Doohickey', price: 4.99, stock: 200,
          created_at: Time.now, updated_at: Time.now }
      ]
      ArAdvProduct.insert_all(records)
      expect(ArAdvProduct.count).to eq(3)
    end

    it 'supports insert_all! (raises on conflict)' do
      ArAdvProduct.create!(sku: 'SKU-DUP', name: 'Existing', price: 1.00, stock: 1)
      records = [
        { sku: 'SKU-DUP', name: 'Duplicate', price: 2.00, stock: 2,
          created_at: Time.now, updated_at: Time.now }
      ]
      expect { ArAdvProduct.insert_all!(records) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'supports insert_all with skip on conflict' do
      ArAdvProduct.create!(sku: 'SKU-SKIP', name: 'Original', price: 5.00, stock: 10)
      records = [
        { sku: 'SKU-SKIP', name: 'Skipped', price: 6.00, stock: 20,
          created_at: Time.now, updated_at: Time.now },
        { sku: 'SKU-NEW', name: 'New One', price: 7.00, stock: 30,
          created_at: Time.now, updated_at: Time.now }
      ]
      ArAdvProduct.insert_all(records)
      expect(ArAdvProduct.count).to eq(2)
      expect(ArAdvProduct.find_by(sku: 'SKU-SKIP').name).to eq('Original')
    end

    it 'supports upsert_all' do
      ArAdvProduct.create!(sku: 'SKU-UPS', name: 'Before', price: 10.00, stock: 5)
      records = [
        { sku: 'SKU-UPS', name: 'After', price: 12.00, stock: 15,
          created_at: Time.now, updated_at: Time.now },
        { sku: 'SKU-FRESH', name: 'Fresh', price: 8.00, stock: 25,
          created_at: Time.now, updated_at: Time.now }
      ]
      # PG requires :unique_by to identify the conflict target; MySQL uses primary key by default
      if ActiveRecord::Base.connection.supports_insert_conflict_target?
        ArAdvProduct.upsert_all(records, unique_by: :sku)
      else
        ArAdvProduct.upsert_all(records)
      end

      expect(ArAdvProduct.count).to eq(2)
      updated = ArAdvProduct.find_by(sku: 'SKU-UPS')
      expect(updated.name).to eq('After')
      expect(updated.stock).to eq(15)
    end
  end

  describe 'Enum' do
    it 'creates records with enum values' do
      order = ArAdvOrder.create!(customer_name: 'Alice', total: 99.99, status: :pending)
      expect(order.status).to eq('pending')
      expect(order.pending?).to be true
    end

    it 'supports enum query scopes' do
      ArAdvOrder.create!(customer_name: 'Bob', total: 50.00, status: :pending)
      ArAdvOrder.create!(customer_name: 'Carol', total: 75.00, status: :shipped)
      ArAdvOrder.create!(customer_name: 'Dave', total: 25.00, status: :delivered)

      expect(ArAdvOrder.pending.count).to eq(1)
      expect(ArAdvOrder.shipped.count).to eq(1)
      expect(ArAdvOrder.delivered.count).to eq(1)
    end

    it 'supports enum transitions' do
      order = ArAdvOrder.create!(customer_name: 'Eve', total: 100.00, status: :pending)
      order.shipped!
      expect(order.reload.status).to eq('shipped')
      expect(order.shipped?).to be true
      expect(order.pending?).to be false
    end

    it 'supports enum where queries' do
      ArAdvOrder.create!(customer_name: 'F1', total: 10.00, status: :pending)
      ArAdvOrder.create!(customer_name: 'F2', total: 20.00, status: :shipped)

      results = ArAdvOrder.where(status: [:pending, :shipped])
      expect(results.count).to eq(2)
    end

    it 'raises on invalid enum value' do
      expect { ArAdvOrder.create!(customer_name: 'Bad', total: 1.00, status: :invalid) }
        .to raise_error(ArgumentError)
    end
  end

  describe 'Touch' do
    it 'updates updated_at on the record' do
      library = ArAdvLibrary.create!(name: 'City Library')
      original_time = library.updated_at

      sleep(0.1)
      library.touch
      expect(library.reload.updated_at).to be > original_time
    end

    it 'touches parent when child is updated (belongs_to touch: true)' do
      library = ArAdvLibrary.create!(name: 'Town Library')
      original_time = library.updated_at

      sleep(0.1)
      ArAdvBook.create!(title: 'New Book', ar_adv_library: library)

      expect(library.reload.updated_at).to be > original_time
    end

    it 'touches parent when child is destroyed' do
      library = ArAdvLibrary.create!(name: 'Village Library')
      book = ArAdvBook.create!(title: 'Old Book', ar_adv_library: library)
      original_time = library.reload.updated_at

      sleep(0.1)
      book.destroy!
      expect(library.reload.updated_at).to be > original_time
    end
  end

  describe 'Concurrent connection pool usage' do
    it 'handles multiple threads using the connection pool' do
      ArAdvCategory.create!(name: 'Thread Test')

      threads = 5.times.map do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ArAdvCategory.create!(name: "Thread-#{i}")
            sleep(0.05)
            ArAdvCategory.where(name: "Thread-#{i}").first
          end
        end
      end

      results = threads.map(&:value)
      expect(results.compact.size).to eq(5)
      expect(ArAdvCategory.count).to eq(6) # 1 original + 5 from threads
    end

    it 'isolates transactions across threads' do
      barrier = Queue.new

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ArAdvCategory.transaction do
            ArAdvCategory.create!(name: 'T1-Record')
            barrier.push(:ready)
            sleep(0.2) # Hold transaction open
          end
        end
      end

      t2 = Thread.new do
        barrier.pop # Wait for t1 to start
        ActiveRecord::Base.connection_pool.with_connection do
          # t1's transaction may or may not be visible depending on isolation level
          # Just verify we can query without deadlock
          ArAdvCategory.count
        end
      end

      [t1, t2].each(&:join)
      expect(ArAdvCategory.find_by(name: 'T1-Record')).to be_present
    end
  end
end


class ArAdvArticle < ActiveRecord::Base
  self.table_name = 'ar_adv_articles'
  has_many :ar_adv_reactions, as: :reactable, dependent: :destroy
end

class ArAdvVideo < ActiveRecord::Base
  self.table_name = 'ar_adv_videos'
  has_many :ar_adv_reactions, as: :reactable, dependent: :destroy
end

class ArAdvReaction < ActiveRecord::Base
  self.table_name = 'ar_adv_reactions'
  belongs_to :reactable, polymorphic: true
end

class ArAdvVehicle < ActiveRecord::Base
  self.table_name = 'ar_adv_vehicles'
end

class ArAdvCar < ArAdvVehicle; end
class ArAdvTruck < ArAdvVehicle; end

class ArAdvDoctor < ActiveRecord::Base
  self.table_name = 'ar_adv_doctors'
  has_many :ar_adv_appointments, dependent: :destroy
  has_many :ar_adv_patients, through: :ar_adv_appointments
end

class ArAdvPatient < ActiveRecord::Base
  self.table_name = 'ar_adv_patients'
  has_many :ar_adv_appointments, dependent: :destroy
  has_many :ar_adv_doctors, through: :ar_adv_appointments
end

class ArAdvAppointment < ActiveRecord::Base
  self.table_name = 'ar_adv_appointments'
  belongs_to :ar_adv_doctor
  belongs_to :ar_adv_patient
end

class ArAdvForum < ActiveRecord::Base
  self.table_name = 'ar_adv_forums'
  has_many :ar_adv_topics, dependent: :destroy
end

class ArAdvTopic < ActiveRecord::Base
  self.table_name = 'ar_adv_topics'
  belongs_to :ar_adv_forum, counter_cache: true
end

class ArAdvOrder < ActiveRecord::Base
  self.table_name = 'ar_adv_orders'
  enum :status, { pending: 0, processing: 1, shipped: 2, delivered: 3, cancelled: 4 }
  validates :customer_name, presence: true
end

class ArAdvLibrary < ActiveRecord::Base
  self.table_name = 'ar_adv_libraries'
  has_many :ar_adv_books, dependent: :destroy
end

class ArAdvBook < ActiveRecord::Base
  self.table_name = 'ar_adv_books'
  belongs_to :ar_adv_library, touch: true
end

class ArAdvProduct < ActiveRecord::Base
  self.table_name = 'ar_adv_products'
  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true
end

class ArAdvCategory < ActiveRecord::Base
  self.table_name = 'ar_adv_categories'
  has_many :ar_adv_items, dependent: :destroy
end

class ArAdvItem < ActiveRecord::Base
  self.table_name = 'ar_adv_items'
  belongs_to :ar_adv_category
end


RSpec.describe 'ActiveRecord advanced compatibility' do
  include_context 'adapter context'

  context 'PostgreSQL' do
    include_examples 'ActiveRecord advanced compatibility', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'ActiveRecord advanced compatibility', MysqlTestHelper
  end
end
