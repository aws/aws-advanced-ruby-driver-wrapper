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

require_relative 'integration_helper'
require_relative 'utils/test_utils'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/proxy_helper'
require_relative 'utils/connection_utils'
require_relative 'utils/database_engine'
require_relative 'utils/rds_test_utility'
require_relative 'utils/retry_helper'
require 'aws_ruby_database_driver_wrapper'

RSpec.describe 'Failover', :integration,
               features: [Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA], # TODO: add multi-AZ cluster
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:proxy_info) { env.proxy_database_info }
  let(:current_writer) { proxy_info.instances.first.instance_id }

  let(:failover_props) do
    {
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::PLUGINS.name => 'failover',
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 90,
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_INSTANCE_HOST_PATTERN.name =>
        "?.#{proxy_info.instance_endpoint_suffix}:#{proxy_info.instance_endpoint_port}",
      connect_timeout: 10
    }
  end

  def failover_connect(host:, port:)
    config = Integration::DriverHelper.native_config(
      drv,
      host: host,
      port: port,
      user: proxy_info.username,
      password: proxy_info.password,
      dbname: proxy_info.default_dbname
    )
    Integration::DriverHelper.wrapper_connect(drv, **config, **failover_props)
  end

  def query_instance_id(conn)
    rds_util.query_instance_id(conn)
  end

  def execute_sql(conn, sql)
    Integration::DriverHelper.execute(drv, conn, sql)
  end

  describe 'writer failover' do
    it 'fails over on connection invocation when writer dies',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)

      rds_util.crash_instance(current_writer)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over on connection bound object invocation (mysql2 prepared statement)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::MYSQL] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)
      stmt = conn.prepare('SELECT 1')

      rds_util.crash_instance(current_writer)

      expect { stmt.execute }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over within transaction',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)

      execute_sql(conn, 'DROP TABLE IF EXISTS test_failover_transaction')
      execute_sql(conn, 'CREATE TABLE test_failover_transaction (id int not null primary key, val varchar(255) not null)')
      execute_sql(conn, 'BEGIN')
      execute_sql(conn, "INSERT INTO test_failover_transaction VALUES (1, 'value1')")

      rds_util.crash_instance(current_writer)

      expect { execute_sql(conn, "INSERT INTO test_failover_transaction VALUES (2, 'value2')") }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::TransactionStateUnknownError
      )

      current_connection_id = query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true

      result = execute_sql(conn, 'SELECT count(*) AS cnt FROM test_failover_transaction')
      count = result.first.is_a?(Hash) ? result.first.values.first : result.first[0]
      expect(count.to_i).to eq(0)

      execute_sql(conn, 'DROP TABLE IF EXISTS test_failover_transaction')
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'writer is re-elected after temporary failure',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      conn = failover_connect(host: initial_writer_instance.host, port: initial_writer_instance.port)

      rds_util.simulate_temporary_failure(current_writer, 0, 15)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = query_instance_id(conn)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'preserves connection properties after failover (pg application_name)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::PG] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      props = failover_props.merge('application_name' => 'failover_props_test')
      config = Integration::DriverHelper.native_config(
        drv,
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        user: proxy_info.username,
        password: proxy_info.password,
        dbname: proxy_info.default_dbname
      )
      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)
      expect(conn.conninfo_hash[:application_name]).to eq('failover_props_test')

      rds_util.crash_instance(current_writer)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      expect(conn.conninfo_hash[:application_name]).to eq('failover_props_test')
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'preserves connection properties after failover (mysql read_timeout)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED],
       enable_on_engines: [Integration::DatabaseEngine::MYSQL] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      props = failover_props.merge(read_timeout: 13)
      config = Integration::DriverHelper.native_config(
        drv,
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        user: proxy_info.username,
        password: proxy_info.password,
        dbname: proxy_info.default_dbname
      )
      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)

      expect(conn.query_options[:read_timeout]).to eq(13)

      rds_util.crash_instance(current_writer)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      expect(conn.query_options[:read_timeout]).to eq(13)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end

  describe 'reader failover' do
    it 'fails over from reader to writer when no other reader available',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2, max_instances: 2)

      reader_instance = proxy_info.instances[1]
      conn = failover_connect(host: reader_instance.host, port: reader_instance.port)

      Integration::ProxyHelper.disable_connectivity(reader_instance.instance_id)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = query_instance_id(conn)
      expect(current_connection_id).to eq(current_writer)
      expect(Integration::RetryHelper.verify_writer(rds_util, current_connection_id)).to be true
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over with reader_or_writer mode',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      props = failover_props.merge(
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_MODE.name => 'reader_or_writer'
      )
      config = Integration::DriverHelper.native_config(
        drv,
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        user: proxy_info.username,
        password: proxy_info.password,
        dbname: proxy_info.default_dbname
      )
      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)

      Integration::ProxyHelper.disable_connectivity(current_writer)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'fails over with strict_reader mode to a reader instance',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      props = failover_props.merge(
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_MODE.name => 'strict_reader',
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 600
      )
      config = Integration::DriverHelper.native_config(
        drv,
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        user: proxy_info.username,
        password: proxy_info.password,
        dbname: proxy_info.default_dbname
      )
      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)

      rds_util.crash_instance(current_writer)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      current_connection_id = query_instance_id(conn)
      expect(
        Integration::RetryHelper.retry_until { !rds_util.db_instance_writer?(current_connection_id) }
      ).to be(true), "Instance #{current_connection_id} is still a writer (API)"
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'writer is re-elected with reader_or_writer mode after temporary failure',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      props = failover_props.merge(
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_MODE.name => 'reader_or_writer'
      )
      config = Integration::DriverHelper.native_config(
        drv,
        host: initial_writer_instance.host,
        port: initial_writer_instance.port,
        user: proxy_info.username,
        password: proxy_info.password,
        dbname: proxy_info.default_dbname
      )
      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **props)

      rds_util.simulate_temporary_failure(current_writer, 0, 5)

      expect { query_instance_id(conn) }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end
end
