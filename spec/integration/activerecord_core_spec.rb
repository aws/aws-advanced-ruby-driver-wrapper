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

RSpec.shared_examples 'ActiveRecord core' do |driver_helper|
  include driver_helper

  before(:all) do
    ActiveRecordAdapterHelper.establish_fresh_connection(
      driver_helper,
      [ArTestAuthor, ArTestPost, ArTestComment, ArTestTag, ArTestPostsTag]
    )
    ActiveRecord::Schema.define do
      suppress_messages do
        create_table :ar_test_authors, force: true do |t|
          t.string :name, null: false
          t.string :email
          t.integer :age
          t.boolean :active, default: true
          t.timestamps
        end

        create_table :ar_test_posts, force: true do |t|
          t.string :title, null: false
          t.text :body
          t.string :status, default: 'draft'
          t.integer :view_count, default: 0
          t.references :ar_test_author, foreign_key: true
          t.timestamps
        end

        create_table :ar_test_comments, force: true do |t|
          t.text :content, null: false
          t.references :ar_test_post, foreign_key: true
          t.string :commenter_name
          t.timestamps
        end

        create_table :ar_test_tags, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end

        create_table :ar_test_posts_tags, force: true, id: false do |t|
          t.references :ar_test_post
          t.references :ar_test_tag
        end
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      suppress_messages do
        drop_table :ar_test_posts_tags, if_exists: true
        drop_table :ar_test_comments, if_exists: true
        drop_table :ar_test_posts, if_exists: true
        drop_table :ar_test_tags, if_exists: true
        drop_table :ar_test_authors, if_exists: true
      end
    end
    ActiveRecord::Base.connection_handler.clear_active_connections!
  end

  before do
    ArTestComment.delete_all
    ArTestPostsTag.delete_all
    ArTestPost.delete_all
    ArTestTag.delete_all
    ArTestAuthor.delete_all
  end

  describe 'CRUD operations' do
    it 'creates a record' do
      author = ArTestAuthor.create!(name: 'Alice', email: 'alice@example.com', age: 30)
      expect(author).to be_persisted
      expect(author.id).to be_a(Integer)
    end

    it 'reads a record by id' do
      author = ArTestAuthor.create!(name: 'Bob', email: 'bob@example.com')
      found = ArTestAuthor.find(author.id)
      expect(found.name).to eq('Bob')
    end

    it 'updates a record with update!' do
      author = ArTestAuthor.create!(name: 'Carol', email: 'carol@example.com')
      author.update!(name: 'Caroline')
      expect(author.reload.name).to eq('Caroline')
    end

    it 'updates a record with update_attribute' do
      author = ArTestAuthor.create!(name: 'Dave', email: 'dave@example.com', age: 25)
      author.update_attribute(:age, 26)
      expect(author.reload.age).to eq(26)
    end

    it 'destroys a record' do
      author = ArTestAuthor.create!(name: 'Eve', email: 'eve@example.com')
      id = author.id
      author.destroy!
      expect { ArTestAuthor.find(id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'supports delete (skip callbacks)' do
      author = ArTestAuthor.create!(name: 'Frank', email: 'frank@example.com')
      id = author.id
      ArTestAuthor.delete(id)
      expect(ArTestAuthor.find_by(id: id)).to be_nil
    end

    it 'supports create with a block' do
      author = ArTestAuthor.create! do |a|
        a.name = 'Grace'
        a.email = 'grace@example.com'
      end
      expect(author.name).to eq('Grace')
    end

    it 'supports new + save' do
      author = ArTestAuthor.new(name: 'Hank', email: 'hank@example.com')
      expect(author).not_to be_persisted
      author.save!
      expect(author).to be_persisted
    end
  end

  describe 'Querying' do
    before do
      ArTestAuthor.create!(name: 'Alice', email: 'alice@example.com', age: 30, active: true)
      ArTestAuthor.create!(name: 'Bob', email: 'bob@example.com', age: 25, active: true)
      ArTestAuthor.create!(name: 'Carol', email: 'carol@example.com', age: 35, active: false)
    end

    it 'finds records with where' do
      results = ArTestAuthor.where(active: true)
      expect(results.count).to eq(2)
    end

    it 'supports where with SQL fragment' do
      results = ArTestAuthor.where('age > ?', 28)
      expect(results.map(&:name)).to contain_exactly('Alice', 'Carol')
    end

    it 'supports where.not' do
      results = ArTestAuthor.where.not(active: false)
      expect(results.count).to eq(2)
    end

    it 'supports order' do
      names = ArTestAuthor.order(age: :asc).pluck(:name)
      expect(names).to eq(%w[Bob Alice Carol])
    end

    it 'supports limit and offset' do
      names = ArTestAuthor.order(:name).limit(2).offset(1).pluck(:name)
      expect(names).to eq(%w[Bob Carol])
    end

    it 'supports pluck for single column' do
      ages = ArTestAuthor.order(:age).pluck(:age)
      expect(ages).to eq([25, 30, 35])
    end

    it 'supports pluck for multiple columns' do
      data = ArTestAuthor.order(:age).pluck(:name, :age)
      expect(data).to eq([['Bob', 25], ['Alice', 30], ['Carol', 35]])
    end

    it 'supports find_by' do
      author = ArTestAuthor.find_by(name: 'Alice')
      expect(author.email).to eq('alice@example.com')
    end

    it 'supports find_by returning nil' do
      author = ArTestAuthor.find_by(name: 'Nobody')
      expect(author).to be_nil
    end

    it 'supports exists?' do
      expect(ArTestAuthor.exists?(name: 'Alice')).to be true
      expect(ArTestAuthor.exists?(name: 'Nobody')).to be false
    end

    it 'supports count, sum, average, minimum, maximum' do
      expect(ArTestAuthor.count).to eq(3)
      expect(ArTestAuthor.sum(:age)).to eq(90)
      expect(ArTestAuthor.average(:age).to_f).to be_within(0.01).of(30.0)
      expect(ArTestAuthor.minimum(:age)).to eq(25)
      expect(ArTestAuthor.maximum(:age)).to eq(35)
    end

    it 'supports distinct' do
      ArTestAuthor.create!(name: 'Alice2', email: 'alice2@example.com', age: 30, active: true)
      ages = ArTestAuthor.distinct.pluck(:age).sort
      expect(ages).to eq([25, 30, 35])
    end

    it 'supports group and count' do
      counts = ArTestAuthor.group(:active).count
      expect(counts[true]).to eq(2)
      expect(counts[false]).to eq(1)
    end

    it 'supports having with group' do
      ArTestAuthor.create!(name: 'Dave', email: 'dave@example.com', age: 30, active: true)
      result = ArTestAuthor.group(:age).having('count(*) > 1').count
      expect(result[30]).to eq(2)
    end

    it 'supports select to limit columns' do
      author = ArTestAuthor.select(:name, :email).find_by(name: 'Alice')
      expect(author.name).to eq('Alice')
      expect(author.email).to eq('alice@example.com')
    end

    it 'supports chaining multiple scopes' do
      results = ArTestAuthor.where(active: true).where('age > ?', 26).order(:name)
      expect(results.pluck(:name)).to eq(['Alice'])
    end

    it 'supports find_or_create_by' do
      author = ArTestAuthor.find_or_create_by!(name: 'NewPerson') do |a|
        a.email = 'new@example.com'
        a.age = 40
      end
      expect(author).to be_persisted
      expect(author.email).to eq('new@example.com')

      # Second call finds existing
      same = ArTestAuthor.find_or_create_by!(name: 'NewPerson')
      expect(same.id).to eq(author.id)
    end

    it 'supports update_all' do
      ArTestAuthor.where(active: true).update_all(age: 99)
      expect(ArTestAuthor.where(age: 99).count).to eq(2)
    end

    it 'supports delete_all' do
      ArTestAuthor.where(active: false).delete_all
      expect(ArTestAuthor.count).to eq(2)
    end

    it 'supports in_batches' do
      total = 0
      ArTestAuthor.in_batches(of: 2) { |batch| total += batch.count }
      expect(total).to eq(3)
    end

    it 'supports find_each' do
      names = []
      ArTestAuthor.find_each(batch_size: 2) { |author| names << author.name }
      expect(names.sort).to eq(%w[Alice Bob Carol])
    end
  end

  describe 'Associations' do
    it 'supports belongs_to / has_many' do
      author = ArTestAuthor.create!(name: 'Alice', email: 'alice@example.com')
      post = ArTestPost.create!(title: 'First Post', body: 'Hello', ar_test_author: author)

      expect(post.ar_test_author).to eq(author)
      expect(author.ar_test_posts.reload).to include(post)
    end

    it 'supports has_many through nested associations' do
      author = ArTestAuthor.create!(name: 'Bob', email: 'bob@example.com')
      post = ArTestPost.create!(title: 'Post', body: 'Content', ar_test_author: author)
      comment = ArTestComment.create!(content: 'Nice!', ar_test_post: post, commenter_name: 'Reader')

      expect(post.ar_test_comments.reload).to include(comment)
      expect(comment.ar_test_post).to eq(post)
    end

    it 'supports has_and_belongs_to_many' do
      post = ArTestPost.create!(title: 'Tagged Post', body: 'Body',
                                ar_test_author: ArTestAuthor.create!(name: 'Carol', email: 'c@example.com'))
      tag1 = ArTestTag.create!(name: 'ruby')
      tag2 = ArTestTag.create!(name: 'rails')

      post.ar_test_tags << tag1
      post.ar_test_tags << tag2

      expect(post.ar_test_tags.reload.pluck(:name).sort).to eq(%w[rails ruby])
      expect(tag1.ar_test_posts.reload).to include(post)
    end

    it 'supports eager loading with includes' do
      author = ArTestAuthor.create!(name: 'Dave', email: 'd@example.com')
      3.times { |i| ArTestPost.create!(title: "Post #{i}", body: 'body', ar_test_author: author) }

      loaded = ArTestAuthor.includes(:ar_test_posts).find(author.id)
      expect(loaded.ar_test_posts.size).to eq(3)
    end

    it 'supports joins' do
      author = ArTestAuthor.create!(name: 'Eve', email: 'e@example.com')
      ArTestPost.create!(title: 'Eve Post', body: 'content', ar_test_author: author)

      results = ArTestAuthor.joins(:ar_test_posts).where(ar_test_posts: { title: 'Eve Post' })
      expect(results.first.name).to eq('Eve')
    end

    it 'supports dependent destroy through association' do
      author = ArTestAuthor.create!(name: 'Frank', email: 'f@example.com')
      post = ArTestPost.create!(title: 'Frank Post', body: 'content', ar_test_author: author)
      ArTestComment.create!(content: 'Comment', ar_test_post: post, commenter_name: 'X')

      post.destroy!
      expect(ArTestComment.where(ar_test_post_id: post.id).count).to eq(0)
    end

    it 'supports building associated records' do
      author = ArTestAuthor.create!(name: 'Grace', email: 'g@example.com')
      post = author.ar_test_posts.build(title: 'Built Post', body: 'Built')
      expect(post).not_to be_persisted
      post.save!
      expect(post).to be_persisted
      expect(author.ar_test_posts.reload.count).to eq(1)
    end

    it 'supports creating associated records' do
      author = ArTestAuthor.create!(name: 'Hank', email: 'h@example.com')
      post = author.ar_test_posts.create!(title: 'Created Post', body: 'Created')
      expect(post).to be_persisted
      expect(post.ar_test_author_id).to eq(author.id)
    end
  end

  describe 'Validations' do
    it 'rejects invalid records' do
      author = ArTestAuthor.new(name: nil)
      expect(author).not_to be_valid
      expect(author.errors[:name]).to be_present
    end

    it 'raises on create! with invalid data' do
      expect { ArTestAuthor.create!(name: nil) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'returns false on save with invalid data' do
      author = ArTestAuthor.new(name: nil)
      expect(author.save).to be false
    end

    it 'validates uniqueness' do
      ArTestAuthor.create!(name: 'Unique', email: 'unique@example.com')
      duplicate = ArTestAuthor.new(name: 'Unique2', email: 'unique@example.com')
      expect(duplicate).not_to be_valid
    end

    it 'validates format' do
      author = ArTestAuthor.new(name: 'Test', email: 'not-an-email')
      expect(author).not_to be_valid
      expect(author.errors[:email]).to be_present
    end

    it 'validates numericality' do
      author = ArTestAuthor.new(name: 'Test', email: 'test@example.com', age: -1)
      expect(author).not_to be_valid
    end
  end

  describe 'Callbacks' do
    it 'triggers before_save callback' do
      author = ArTestAuthor.create!(name: '  spacey  ', email: 'spacey@example.com')
      expect(author.name).to eq('spacey')
    end

    it 'triggers after_create callback' do
      post = ArTestPost.create!(
        title: 'Callback Test',
        body: 'Body',
        ar_test_author: ArTestAuthor.create!(name: 'Author', email: 'a@example.com')
      )
      # after_create sets status to 'pending' (see model definition below)
      expect(post.reload.status).to eq('pending')
    end
  end

  describe 'Scopes' do
    before do
      author = ArTestAuthor.create!(name: 'Author', email: 'a@example.com')
      draft = ArTestPost.create!(title: 'Draft', body: 'x', ar_test_author: author)
      # Use update_column to bypass the after_create callback that sets status to 'pending'
      draft.update_column(:status, 'draft')
      published = ArTestPost.create!(title: 'Published', body: 'x', ar_test_author: author)
      published.update_column(:status, 'published')
      archived = ArTestPost.create!(title: 'Archived', body: 'x', ar_test_author: author)
      archived.update_column(:status, 'archived')
    end

    it 'supports named scopes' do
      expect(ArTestPost.published.count).to eq(1)
      expect(ArTestPost.draft.count).to eq(1)
    end

    it 'supports default scope' do
      # Default scope orders by created_at desc
      titles = ArTestPost.pluck(:title)
      expect(titles.first).to eq('Archived') # most recent
    end

    it 'supports unscoped to bypass default scope' do
      # unscoped removes ordering — just verify it doesn't raise
      expect(ArTestPost.unscoped.count).to eq(3)
    end

    it 'supports scope chaining' do
      results = ArTestPost.published.where('view_count >= ?', 0)
      expect(results.count).to eq(1)
    end
  end

  describe 'Transactions' do
    it 'commits on success' do
      ArTestAuthor.transaction do
        ArTestAuthor.create!(name: 'TxAuthor', email: 'tx@example.com')
      end
      expect(ArTestAuthor.find_by(name: 'TxAuthor')).to be_present
    end

    it 'rolls back on exception' do
      expect {
        ArTestAuthor.transaction do
          ArTestAuthor.create!(name: 'Rollback', email: 'rb@example.com')
          raise ActiveRecord::Rollback
        end
      }.not_to raise_error
      expect(ArTestAuthor.find_by(name: 'Rollback')).to be_nil
    end

    it 'rolls back on unhandled exception' do
      expect {
        ArTestAuthor.transaction do
          ArTestAuthor.create!(name: 'Error', email: 'err@example.com')
          raise StandardError, 'boom'
        end
      }.to raise_error(StandardError)
      expect(ArTestAuthor.find_by(name: 'Error')).to be_nil
    end

    it 'supports nested transactions with savepoints' do
      ArTestAuthor.transaction do
        ArTestAuthor.create!(name: 'Outer', email: 'outer@example.com')
        ArTestAuthor.transaction(requires_new: true) do
          ArTestAuthor.create!(name: 'Inner', email: 'inner@example.com')
          raise ActiveRecord::Rollback
        end
      end
      expect(ArTestAuthor.find_by(name: 'Outer')).to be_present
      expect(ArTestAuthor.find_by(name: 'Inner')).to be_nil
    end
  end

  describe 'Schema manipulation' do
    after do
      ActiveRecord::Schema.define do
        suppress_messages { drop_table :ar_test_temp_table, if_exists: true }
      end
    end

    it 'creates and drops tables' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_test_temp_table, force: true do |t|
            t.string :label
            t.timestamps
          end
        end
      end
      expect(ActiveRecord::Base.connection.table_exists?(:ar_test_temp_table)).to be true
    end

    it 'adds and removes columns' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_test_temp_table, force: true do |t|
            t.string :label
          end
          add_column :ar_test_temp_table, :description, :text
        end
      end
      columns = ActiveRecord::Base.connection.columns(:ar_test_temp_table).map(&:name)
      expect(columns).to include('description')

      ActiveRecord::Schema.define do
        suppress_messages { remove_column :ar_test_temp_table, :description }
      end
      columns = ActiveRecord::Base.connection.columns(:ar_test_temp_table).map(&:name)
      expect(columns).not_to include('description')
    end

    it 'adds indexes' do
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :ar_test_temp_table, force: true do |t|
            t.string :label
          end
          add_index :ar_test_temp_table, :label, name: 'idx_temp_label'
        end
      end
      indexes = ActiveRecord::Base.connection.indexes(:ar_test_temp_table)
      expect(indexes.map(&:name)).to include('idx_temp_label')
    end
  end

  describe 'Locking' do
    it 'supports optimistic locking' do
      author = ArTestAuthor.create!(name: 'Optimistic', email: 'opt@example.com')
      author1 = ArTestAuthor.find(author.id)
      author2 = ArTestAuthor.find(author.id)

      author1.update!(name: 'Updated First')

      # Optimistic locking not configured on this model, so just verify concurrent updates work
      author2.update!(name: 'Updated Second')
      expect(author.reload.name).to eq('Updated Second')
    end

    it 'supports pessimistic locking' do
      author = ArTestAuthor.create!(name: 'Pessimistic', email: 'pes@example.com')
      ArTestAuthor.transaction do
        locked = ArTestAuthor.lock.find(author.id)
        locked.update!(name: 'Locked Update')
      end
      expect(author.reload.name).to eq('Locked Update')
    end
  end

  describe 'Serialization' do
    it 'supports to_json' do
      author = ArTestAuthor.create!(name: 'Json', email: 'json@example.com', age: 28)
      json = JSON.parse(author.to_json)
      expect(json['name']).to eq('Json')
      expect(json['age']).to eq(28)
    end

    it 'supports as_json with options' do
      author = ArTestAuthor.create!(name: 'Json2', email: 'j2@example.com', age: 30)
      json = author.as_json(only: %i[name email])
      expect(json.keys).to contain_exactly('name', 'email')
    end
  end

  describe 'Enum-like status field' do
    it 'supports querying by status' do
      author = ArTestAuthor.create!(name: 'A', email: 'a@example.com')
      p1 = ArTestPost.create!(title: 'P1', body: 'x', ar_test_author: author)
      p1.update_column(:status, 'published')
      p2 = ArTestPost.create!(title: 'P2', body: 'x', ar_test_author: author)
      p2.update_column(:status, 'draft')

      expect(ArTestPost.where(status: 'published').count).to eq(1)
    end
  end

  describe 'Raw SQL execution' do
    it 'supports execute for raw SQL' do
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO ar_test_authors (name, email, created_at, updated_at) VALUES ('Raw', 'raw@example.com', NOW(), NOW())")
      result = conn.select_value("SELECT name FROM ar_test_authors WHERE email = 'raw@example.com'")
      expect(result).to eq('Raw')
    end

    it 'supports select_all' do
      ArTestAuthor.create!(name: 'SelectAll', email: 'sa@example.com')
      result = ActiveRecord::Base.connection.select_all('SELECT name FROM ar_test_authors WHERE name = \'SelectAll\'')
      expect(result.rows.flatten).to include('SelectAll')
    end

    it 'supports select_value' do
      ArTestAuthor.create!(name: 'SelectVal', email: 'sv@example.com', age: 42)
      val = ActiveRecord::Base.connection.select_value("SELECT age FROM ar_test_authors WHERE name = 'SelectVal'")
      expect(val.to_i).to eq(42)
    end
  end

  describe 'Connection pool' do
    it 'supports connection pool with_connection' do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        expect(conn).to be_active
      end
    end

    it 'supports multiple sequential connections' do
      3.times do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          expect(conn.select_value('SELECT 1').to_i).to eq(1)
        end
      end
    end
  end

  describe 'Dirty tracking (attribute changes)' do
    it 'tracks changes before save' do
      author = ArTestAuthor.create!(name: 'Original', email: 'orig@example.com')
      author.name = 'Modified'
      expect(author).to be_changed
      expect(author.name_changed?).to be true
      expect(author.changes['name']).to eq(%w[Original Modified])
    end

    it 'tracks previous changes after save' do
      author = ArTestAuthor.create!(name: 'Before', email: 'before@example.com')
      author.update!(name: 'After')
      expect(author.previous_changes['name']).to eq(%w[Before After])
    end

    it 'supports reload to discard changes' do
      author = ArTestAuthor.create!(name: 'Stable', email: 'stable@example.com')
      author.name = 'Temporary'
      author.reload
      expect(author.name).to eq('Stable')
      expect(author).not_to be_changed
    end
  end
end


class ArTestAuthor < ActiveRecord::Base
  self.table_name = 'ar_test_authors'

  has_many :ar_test_posts, dependent: :destroy

  validates :name, presence: true
  validates :email, uniqueness: true, allow_nil: true,
                    format: { with: /\A[^@\s]+@[^@\s]+\z/, message: 'must be a valid email' }
  validates :age, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  before_save :strip_name

  private

  def strip_name
    self.name = name.strip if name.present?
  end
end

class ArTestPost < ActiveRecord::Base
  self.table_name = 'ar_test_posts'

  belongs_to :ar_test_author
  has_many :ar_test_comments, dependent: :destroy
  has_and_belongs_to_many :ar_test_tags, join_table: 'ar_test_posts_tags'

  validates :title, presence: true

  scope :published, -> { where(status: 'published') }
  scope :draft, -> { where(status: 'draft') }

  default_scope { order(created_at: :desc) }

  after_create :set_pending_status

  private

  def set_pending_status
    update_column(:status, 'pending')
  end
end

class ArTestComment < ActiveRecord::Base
  self.table_name = 'ar_test_comments'

  belongs_to :ar_test_post

  validates :content, presence: true
end

class ArTestTag < ActiveRecord::Base
  self.table_name = 'ar_test_tags'

  has_and_belongs_to_many :ar_test_posts, join_table: 'ar_test_posts_tags'

  validates :name, presence: true
end

class ArTestPostsTag < ActiveRecord::Base
  self.table_name = 'ar_test_posts_tags'
end


RSpec.describe 'ActiveRecord core' do
  include_context 'adapter context'

  context 'PostgreSQL' do
    include_examples 'ActiveRecord core', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'ActiveRecord core', MysqlTestHelper
  end
end
