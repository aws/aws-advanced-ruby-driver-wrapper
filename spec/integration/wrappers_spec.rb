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

RSpec.shared_examples 'Basic wrapper workflows' do |driver_helper|
  include driver_helper

  it 'connects and executes queries' do
    conn = driver_helper.wrapper_connect
    result = driver_helper.execute(conn, 'SELECT 1 AS test')
    expect(result.first['test'].to_i).to eq(1)

    # Check that method_missing works
    driver_helper.server_version(conn)
  ensure
    conn&.close
  end
end

RSpec.describe 'Basic wrapper workflows' do
  context 'PostgreSQL' do
    include_examples 'Basic wrapper workflows', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'Basic wrapper workflows', MysqlTestHelper

    include MysqlTestHelper

    # NOTE: MySQL has a prepared statement object (Mysql2::Statement), but PG does not.
    it 'wraps prepared statement objects' do
      conn = MysqlTestHelper.wrapper_connect
      stmt = conn.prepare('SELECT ? + ? AS total')
      result = stmt.execute(2, 3)
      expect(result.first['total']).to eq(5)
    ensure
      conn.close
    end

    it 'wraps streaming result objects' do
      conn = MysqlTestHelper.wrapper_connect
      result = conn.query('SELECT 1 AS val UNION SELECT 2 UNION SELECT 3', stream: true)
      rows = result.map { |row| row['val'].to_i }
      expect(rows).to eq([1, 2, 3])
    ensure
      conn.close
    end
  end
end
