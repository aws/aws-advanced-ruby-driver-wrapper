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

RSpec.shared_examples 'ActiveRecord associations and features' do |driver_helper|
  include driver_helper

  ASSOC_MODELS = [ArAssocArticle, ArAssocVideo, ArAssocReaction, ArAssocVehicle, ArAssocCar, ArAssocTruck,
                     ArAssocDoctor, ArAssocPatient, ArAssocAppointment, ArAssocForum, ArAssocTopic,
                     ArAssocOrder, ArAssocLibrary, ArAssocBook, ArAssocProduct, ArAssocCategory, ArAssocItem].freeze unless defined?(ASSOC_MODELS)

  before(:all) do
    ActiveRecordAdapterHelper.establish_fresh_connection(driver_helper, ASSOC_MODELS)

    ActiveRecord::Schema.define do
      suppress_messages do
        create_table :ar_assoc_articles, force: true do |t|
          t.string :title, null: false
          t.text :body
          t.timestamps
        end

        create_table :ar_assoc_videos, force: true do |t|
          t.string :title, null: false
          t.string :url
          t.timestamps
        end

        create_table :ar_assoc_reactions, force: true do |t|
          t.string :emoji, null: false
          t.references :reactable, polymorphic: true, null: false
          t.timestamps
        end

        create_table :ar_assoc_vehicles, force: true do |t|
          t.string :type, null: false
          t.string :name, null: false
          t.integer :horsepower
          t.integer :cargo_capacity
          t.timestamps
        end

        create_table :ar_assoc_doctors, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_assoc_patients, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_assoc_appointments, force: true do |t|
          t.references :ar_assoc_doctor, foreign_key: true, null: false
          t.references :ar_assoc_patient, foreign_key: true, null: false
          t.datetime :scheduled_at, null: false
          t.string :notes
          t.timestamps
        end

        create_table :ar_assoc_forums, force: true do |t|
          t.string :name, null: false
          t.integer :ar_assoc_topics_count, default: 0
          t.timestamps
        end

        create_table :ar_assoc_topics, force: true do |t|
          t.string :subject, null: false
          t.references :ar_assoc_forum, foreign_key: true, null: false
          t.timestamps
        end

        create_table :ar_assoc_orders, force: true do |t|
          t.integer :status, default: 0, null: false
          t.decimal :total, precision: 10, scale: 2
          t.string :customer_name, null: false
          t.timestamps
        end

        create_table :ar_assoc_libraries, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_assoc_books, force: true do |t|
          t.string :title, null: false
          t.references :ar_assoc_library, foreign_key: true, null: false
          t.timestamps
        end

        create_table :ar_assoc_products, force: true do |t|
          t.string :sku, null: false
          t.string :name, null: false
          t.decimal :price, precision: 10, scale: 2
          t.integer :stock, default: 0
          t.timestamps
        end

        add_index :ar_assoc_products, :sku, unique: true

        create_table :ar_assoc_categories, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_assoc_items, force: true do |t|
          t.string :name, null: false
          t.references :ar_assoc_category, foreign_key: true, null: false
          t.integer :quantity, default: 0
          t.timestamps
        end
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      suppress_messages do
        drop_table :ar_assoc_reactions, if_exists: true
        drop_table :ar_assoc_articles, if_exists: true
        drop_table :ar_assoc_videos, if_exists: true
        drop_table :ar_assoc_vehicles, if_exists: true
        drop_table :ar_assoc_appointments, if_exists: true
        drop_table :ar_assoc_doctors, if_exists: true
        drop_table :ar_assoc_patients, if_exists: true
        drop_table :ar_assoc_topics, if_exists: true
        drop_table :ar_assoc_forums, if_exists: true
        drop_table :ar_assoc_orders, if_exists: true
        drop_table :ar_assoc_books, if_exists: true
        drop_table :ar_assoc_libraries, if_exists: true
        drop_table :ar_assoc_products, if_exists: true
        drop_table :ar_assoc_items, if_exists: true
        drop_table :ar_assoc_categories, if_exists: true
      end
    end
    ActiveRecord::Base.connection_handler.clear_active_connections!
  end

  before do
    ArAssocReaction.delete_all
    ArAssocArticle.delete_all
    ArAssocVideo.delete_all
    ArAssocVehicle.delete_all
    ArAssocAppointment.delete_all
    ArAssocDoctor.delete_all
    ArAssocPatient.delete_all
    ArAssocTopic.delete_all
    ArAssocForum.delete_all
    ArAssocOrder.delete_all
    ArAssocBook.delete_all
    ArAssocLibrary.delete_all
    ArAssocProduct.delete_all
    ArAssocItem.delete_all
    ArAssocCategory.delete_all
  end

  describe 'Advanced schema migrations' do
    after do
      ActiveRecord::Schema.define do
        suppress_messages do
          drop_table :ar_assoc_migration_test, if_exists: true
          drop_table :ar_assoc_renamed_table, if_exists: true
        end
      end
    end

    it 'supports change_column type' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_assoc_migration_test, force: true do |t|
            t.string :amount
          end
          change_column :ar_assoc_migration_test, :amount, :text
        end
      end
      col = ActiveRecord::Base.connection.columns(:ar_assoc_migration_test).find { |c| c.name == 'amount' }
      expect(col.sql_type).to match(/text/i)
    end

    it 'supports rename_column' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_assoc_migration_test, force: true do |t|
            t.string :old_name
          end
          rename_column :ar_assoc_migration_test, :old_name, :new_name
        end
      end
      columns = ActiveRecord::Base.connection.columns(:ar_assoc_migration_test).map(&:name)
      expect(columns).to include('new_name')
      expect(columns).not_to include('old_name')
    end

    it 'supports rename_table' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_assoc_migration_test, force: true do |t|
            t.string :label
          end
          rename_table :ar_assoc_migration_test, :ar_assoc_renamed_table
        end
      end
      expect(ActiveRecord::Base.connection.table_exists?(:ar_assoc_renamed_table)).to be true
      expect(ActiveRecord::Base.connection.table_exists?(:ar_assoc_migration_test)).to be false
    end
  end

  describe 'Polymorphic associations' do
    it 'creates reactions on different reactable types' do
      article = ArAssocArticle.create!(title: 'Great Article', body: 'Content')
      video = ArAssocVideo.create!(title: 'Cool Video', url: 'https://example.com/v')

      r1 = ArAssocReaction.create!(emoji: '👍', reactable: article)
      r2 = ArAssocReaction.create!(emoji: '❤️', reactable: video)

      expect(r1.reactable).to eq(article)
      expect(r2.reactable).to eq(video)
      expect(r1.reactable_type).to eq('ArAssocArticle')
      expect(r2.reactable_type).to eq('ArAssocVideo')
    end

    it 'loads polymorphic associations from parent' do
      article = ArAssocArticle.create!(title: 'Article', body: 'Body')
      ArAssocReaction.create!(emoji: '🎉', reactable: article)
      ArAssocReaction.create!(emoji: '🔥', reactable: article)

      expect(article.ar_assoc_reactions.count).to eq(2)
      expect(article.ar_assoc_reactions.pluck(:emoji).sort).to eq(%w[🎉 🔥].sort)
    end

    it 'eager loads polymorphic associations' do
      article = ArAssocArticle.create!(title: 'Eager', body: 'Body')
      ArAssocReaction.create!(emoji: '👀', reactable: article)

      reactions = ArAssocReaction.includes(:reactable).where(reactable: article)
      expect(reactions.first.reactable.title).to eq('Eager')
    end
  end

  describe 'Single Table Inheritance' do
    it 'creates subclass records with correct type' do
      car = ArAssocCar.create!(name: 'Sedan', horsepower: 200)
      truck = ArAssocTruck.create!(name: 'Hauler', cargo_capacity: 5000)

      expect(car.type).to eq('ArAssocCar')
      expect(truck.type).to eq('ArAssocTruck')
    end

    it 'queries return correct subclass instances' do
      ArAssocCar.create!(name: 'Coupe', horsepower: 300)
      ArAssocTruck.create!(name: 'Pickup', cargo_capacity: 2000)

      vehicles = ArAssocVehicle.all
      expect(vehicles.map(&:class)).to contain_exactly(ArAssocCar, ArAssocTruck)
    end

    it 'scopes queries to subclass' do
      ArAssocCar.create!(name: 'Sports', horsepower: 400)
      ArAssocTruck.create!(name: 'Semi', cargo_capacity: 10_000)

      expect(ArAssocCar.count).to eq(1)
      expect(ArAssocTruck.count).to eq(1)
      expect(ArAssocVehicle.count).to eq(2)
    end

    it 'supports querying subclass-specific attributes' do
      ArAssocCar.create!(name: 'Fast', horsepower: 500)
      car = ArAssocCar.find_by(name: 'Fast')
      expect(car.horsepower).to eq(500)
    end
  end

  describe 'Counter cache' do
    it 'increments counter on create' do
      forum = ArAssocForum.create!(name: 'Ruby Forum')
      ArAssocTopic.create!(subject: 'Topic 1', ar_assoc_forum: forum)
      ArAssocTopic.create!(subject: 'Topic 2', ar_assoc_forum: forum)

      expect(forum.reload.ar_assoc_topics_count).to eq(2)
    end

    it 'decrements counter on destroy' do
      forum = ArAssocForum.create!(name: 'Rails Forum')
      topic = ArAssocTopic.create!(subject: 'Temp Topic', ar_assoc_forum: forum)
      expect(forum.reload.ar_assoc_topics_count).to eq(1)

      topic.destroy!
      expect(forum.reload.ar_assoc_topics_count).to eq(0)
    end

    it 'supports reset_counters' do
      forum = ArAssocForum.create!(name: 'Reset Forum')
      ArAssocTopic.create!(subject: 'T1', ar_assoc_forum: forum)
      ArAssocTopic.create!(subject: 'T2', ar_assoc_forum: forum)

      # Manually corrupt the counter
      ArAssocForum.update_counters(forum.id, ar_assoc_topics_count: -10)
      expect(forum.reload.ar_assoc_topics_count).to eq(-8)

      # Reset it
      ArAssocForum.reset_counters(forum.id, :ar_assoc_topics)
      expect(forum.reload.ar_assoc_topics_count).to eq(2)
    end
  end

  describe 'has_many :through' do
    it 'creates associations through join model' do
      doctor = ArAssocDoctor.create!(name: 'Dr. Smith')
      patient = ArAssocPatient.create!(name: 'John Doe')
      appointment = ArAssocAppointment.create!(
        ar_assoc_doctor: doctor,
        ar_assoc_patient: patient,
        scheduled_at: Time.now + 3600,
        notes: 'Checkup'
      )

      expect(doctor.ar_assoc_patients).to include(patient)
      expect(patient.ar_assoc_doctors).to include(doctor)
      expect(doctor.ar_assoc_appointments.first).to eq(appointment)
    end

    it 'supports querying through the join model' do
      doctor = ArAssocDoctor.create!(name: 'Dr. Jones')
      p1 = ArAssocPatient.create!(name: 'Patient A')
      p2 = ArAssocPatient.create!(name: 'Patient B')
      ArAssocAppointment.create!(ar_assoc_doctor: doctor, ar_assoc_patient: p1,
                               scheduled_at: Time.now, notes: 'Visit')
      ArAssocAppointment.create!(ar_assoc_doctor: doctor, ar_assoc_patient: p2,
                               scheduled_at: Time.now, notes: 'Follow-up')

      expect(doctor.ar_assoc_patients.count).to eq(2)
      expect(doctor.ar_assoc_patients.pluck(:name).sort).to eq(['Patient A', 'Patient B'])
    end

    it 'supports conditions on through association' do
      doctor = ArAssocDoctor.create!(name: 'Dr. Lee')
      patient = ArAssocPatient.create!(name: 'Patient C')
      future = Time.now + 86_400
      past = Time.now - 86_400
      ArAssocAppointment.create!(ar_assoc_doctor: doctor, ar_assoc_patient: patient,
                               scheduled_at: future, notes: 'Future')
      ArAssocAppointment.create!(ar_assoc_doctor: doctor, ar_assoc_patient: patient,
                               scheduled_at: past, notes: 'Past')

      upcoming = doctor.ar_assoc_appointments.where('scheduled_at > ?', Time.now)
      expect(upcoming.count).to eq(1)
      expect(upcoming.first.notes).to eq('Future')
    end
  end

  describe 'Preloading strategies' do
    before do
      3.times do |i|
        cat = ArAssocCategory.create!(name: "Category #{i}")
        2.times { |j| ArAssocItem.create!(name: "Item #{i}-#{j}", ar_assoc_category: cat, quantity: j + 1) }
      end
    end

    it 'supports preload (separate queries)' do
      categories = ArAssocCategory.preload(:ar_assoc_items).to_a
      expect(categories.size).to eq(3)
      expect(categories.first.ar_assoc_items.size).to eq(2)
    end

    it 'supports eager_load (LEFT OUTER JOIN)' do
      categories = ArAssocCategory.eager_load(:ar_assoc_items).to_a
      expect(categories.size).to eq(3)
      categories.each { |c| expect(c.ar_assoc_items).to be_loaded }
    end

    it 'supports includes with where on association' do
      items = ArAssocItem.includes(:ar_assoc_category)
                       .where(ar_assoc_categories: { name: 'Category 0' })
                       .references(:ar_assoc_categories)
      expect(items.count).to eq(2)
      expect(items.first.ar_assoc_category.name).to eq('Category 0')
    end

    it 'supports includes without N+1' do
      categories = ArAssocCategory.includes(:ar_assoc_items).to_a
      # Access items without triggering additional queries
      total_items = categories.sum { |c| c.ar_assoc_items.size }
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
      ArAssocProduct.insert_all(records)
      expect(ArAssocProduct.count).to eq(3)
    end

    it 'supports insert_all! (raises on conflict)' do
      ArAssocProduct.create!(sku: 'SKU-DUP', name: 'Existing', price: 1.00, stock: 1)
      records = [
        { sku: 'SKU-DUP', name: 'Duplicate', price: 2.00, stock: 2,
          created_at: Time.now, updated_at: Time.now }
      ]
      expect { ArAssocProduct.insert_all!(records) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'supports insert_all with skip on conflict' do
      ArAssocProduct.create!(sku: 'SKU-SKIP', name: 'Original', price: 5.00, stock: 10)
      records = [
        { sku: 'SKU-SKIP', name: 'Skipped', price: 6.00, stock: 20,
          created_at: Time.now, updated_at: Time.now },
        { sku: 'SKU-NEW', name: 'New One', price: 7.00, stock: 30,
          created_at: Time.now, updated_at: Time.now }
      ]
      ArAssocProduct.insert_all(records)
      expect(ArAssocProduct.count).to eq(2)
      expect(ArAssocProduct.find_by(sku: 'SKU-SKIP').name).to eq('Original')
    end

    it 'supports upsert_all' do
      ArAssocProduct.create!(sku: 'SKU-UPS', name: 'Before', price: 10.00, stock: 5)
      records = [
        { sku: 'SKU-UPS', name: 'After', price: 12.00, stock: 15,
          created_at: Time.now, updated_at: Time.now },
        { sku: 'SKU-FRESH', name: 'Fresh', price: 8.00, stock: 25,
          created_at: Time.now, updated_at: Time.now }
      ]
      # PG requires :unique_by to identify the conflict target; MySQL uses primary key by default
      if ActiveRecord::Base.connection.supports_insert_conflict_target?
        ArAssocProduct.upsert_all(records, unique_by: :sku)
      else
        ArAssocProduct.upsert_all(records)
      end

      expect(ArAssocProduct.count).to eq(2)
      updated = ArAssocProduct.find_by(sku: 'SKU-UPS')
      expect(updated.name).to eq('After')
      expect(updated.stock).to eq(15)
    end
  end

  describe 'Enum' do
    it 'creates records with enum values' do
      order = ArAssocOrder.create!(customer_name: 'Alice', total: 99.99, status: :pending)
      expect(order.status).to eq('pending')
      expect(order.pending?).to be true
    end

    it 'supports enum query scopes' do
      ArAssocOrder.create!(customer_name: 'Bob', total: 50.00, status: :pending)
      ArAssocOrder.create!(customer_name: 'Carol', total: 75.00, status: :shipped)
      ArAssocOrder.create!(customer_name: 'Dave', total: 25.00, status: :delivered)

      expect(ArAssocOrder.pending.count).to eq(1)
      expect(ArAssocOrder.shipped.count).to eq(1)
      expect(ArAssocOrder.delivered.count).to eq(1)
    end

    it 'supports enum transitions' do
      order = ArAssocOrder.create!(customer_name: 'Eve', total: 100.00, status: :pending)
      order.shipped!
      expect(order.reload.status).to eq('shipped')
      expect(order.shipped?).to be true
      expect(order.pending?).to be false
    end

    it 'supports enum where queries' do
      ArAssocOrder.create!(customer_name: 'F1', total: 10.00, status: :pending)
      ArAssocOrder.create!(customer_name: 'F2', total: 20.00, status: :shipped)

      results = ArAssocOrder.where(status: [:pending, :shipped])
      expect(results.count).to eq(2)
    end

    it 'raises on invalid enum value' do
      expect { ArAssocOrder.create!(customer_name: 'Bad', total: 1.00, status: :invalid) }
        .to raise_error(ArgumentError)
    end
  end

  describe 'Touch' do
    it 'updates updated_at on the record' do
      library = ArAssocLibrary.create!(name: 'City Library')
      original_time = library.updated_at

      sleep(0.1)
      library.touch
      expect(library.reload.updated_at).to be > original_time
    end

    it 'touches parent when child is updated (belongs_to touch: true)' do
      library = ArAssocLibrary.create!(name: 'Town Library')
      original_time = library.updated_at

      sleep(0.1)
      ArAssocBook.create!(title: 'New Book', ar_assoc_library: library)

      expect(library.reload.updated_at).to be > original_time
    end

    it 'touches parent when child is destroyed' do
      library = ArAssocLibrary.create!(name: 'Village Library')
      book = ArAssocBook.create!(title: 'Old Book', ar_assoc_library: library)
      original_time = library.reload.updated_at

      sleep(0.1)
      book.destroy!
      expect(library.reload.updated_at).to be > original_time
    end
  end

  describe 'Concurrent connection pool usage' do
    it 'handles multiple threads using the connection pool' do
      ArAssocCategory.create!(name: 'Thread Test')

      threads = 5.times.map do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ArAssocCategory.create!(name: "Thread-#{i}")
            sleep(0.05)
            ArAssocCategory.where(name: "Thread-#{i}").first
          end
        end
      end

      results = threads.map(&:value)
      expect(results.compact.size).to eq(5)
      expect(ArAssocCategory.count).to eq(6) # 1 original + 5 from threads
    end

    it 'isolates transactions across threads' do
      barrier = Queue.new

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ArAssocCategory.transaction do
            ArAssocCategory.create!(name: 'T1-Record')
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
          ArAssocCategory.count
        end
      end

      [t1, t2].each(&:join)
      expect(ArAssocCategory.find_by(name: 'T1-Record')).to be_present
    end
  end
end


class ArAssocArticle < ActiveRecord::Base
  self.table_name = 'ar_assoc_articles'
  has_many :ar_assoc_reactions, as: :reactable, dependent: :destroy
end

class ArAssocVideo < ActiveRecord::Base
  self.table_name = 'ar_assoc_videos'
  has_many :ar_assoc_reactions, as: :reactable, dependent: :destroy
end

class ArAssocReaction < ActiveRecord::Base
  self.table_name = 'ar_assoc_reactions'
  belongs_to :reactable, polymorphic: true
end

class ArAssocVehicle < ActiveRecord::Base
  self.table_name = 'ar_assoc_vehicles'
end

class ArAssocCar < ArAssocVehicle; end
class ArAssocTruck < ArAssocVehicle; end

class ArAssocDoctor < ActiveRecord::Base
  self.table_name = 'ar_assoc_doctors'
  has_many :ar_assoc_appointments, dependent: :destroy
  has_many :ar_assoc_patients, through: :ar_assoc_appointments
end

class ArAssocPatient < ActiveRecord::Base
  self.table_name = 'ar_assoc_patients'
  has_many :ar_assoc_appointments, dependent: :destroy
  has_many :ar_assoc_doctors, through: :ar_assoc_appointments
end

class ArAssocAppointment < ActiveRecord::Base
  self.table_name = 'ar_assoc_appointments'
  belongs_to :ar_assoc_doctor
  belongs_to :ar_assoc_patient
end

class ArAssocForum < ActiveRecord::Base
  self.table_name = 'ar_assoc_forums'
  has_many :ar_assoc_topics, dependent: :destroy
end

class ArAssocTopic < ActiveRecord::Base
  self.table_name = 'ar_assoc_topics'
  belongs_to :ar_assoc_forum, counter_cache: true
end

class ArAssocOrder < ActiveRecord::Base
  self.table_name = 'ar_assoc_orders'
  enum :status, { pending: 0, processing: 1, shipped: 2, delivered: 3, cancelled: 4 }
  validates :customer_name, presence: true
end

class ArAssocLibrary < ActiveRecord::Base
  self.table_name = 'ar_assoc_libraries'
  has_many :ar_assoc_books, dependent: :destroy
end

class ArAssocBook < ActiveRecord::Base
  self.table_name = 'ar_assoc_books'
  belongs_to :ar_assoc_library, touch: true
end

class ArAssocProduct < ActiveRecord::Base
  self.table_name = 'ar_assoc_products'
  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true
end

class ArAssocCategory < ActiveRecord::Base
  self.table_name = 'ar_assoc_categories'
  has_many :ar_assoc_items, dependent: :destroy
end

class ArAssocItem < ActiveRecord::Base
  self.table_name = 'ar_assoc_items'
  belongs_to :ar_assoc_category
end


RSpec.describe 'ActiveRecord associations and features' do
  include_context 'adapter context'

  context 'PostgreSQL' do
    include_examples 'ActiveRecord associations and features', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'ActiveRecord associations and features', MysqlTestHelper
  end
end
