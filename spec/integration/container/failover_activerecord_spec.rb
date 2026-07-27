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

require 'active_record'
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
require 'aws_ruby_database_driver_wrapper/active_record/aws_mysql2_adapter'
require 'aws_ruby_database_driver_wrapper/active_record/aws_postgresql_adapter'

# ActiveRecord failover integration tests.
#
# The raw-driver failover_spec.rb covers the failover plugin mechanics directly. These tests
# instead exercise failover through the ActiveRecord adapters, which have their own plugin-specific
# integration code that is not reachable via the raw driver:
#   * AwsPostgreSQLAdapter / AwsMySQL2Adapter#translate_exception re-raises FailoverSuccessError so
#     the calling query still sees it, but marks the connection for reconfiguration; FailoverFailedError
#     is translated to ActiveRecord::ConnectionFailed.
#   * #verify! runs configure_connection against the new topology once @needs_reconfiguration is set.
RSpec.describe 'Failover (ActiveRecord)', :integration,
               features: [Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:proxy_info) { env.proxy_database_info }
  let(:current_writer) { proxy_info.instances.first.instance_id }

  # AR connection config pointing at the cluster/instance endpoints through the proxy, with the
  # failover plugin enabled. Wrapper property keys pass through the adapter into the wrapper unchanged.
  def failover_adapter_config(host:, port:)
    adapter = case drv
              when Integration::TestDriver::PG    then 'aws_postgresql'
              when Integration::TestDriver::MYSQL then 'aws_mysql2'
              else raise "Unsupported driver: #{drv}"
              end

    {
      adapter: adapter,
      host: host,
      port: port,
      username: proxy_info.username,
      password: proxy_info.password,
      database: proxy_info.default_dbname,
      connect_timeout: 10,
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::PLUGINS.name => 'failover',
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name => 90,
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_INSTANCE_HOST_PATTERN.name =>
        "?.#{proxy_info.instance_endpoint_suffix}:#{proxy_info.instance_endpoint_port}"
    }
  end

  def establish_failover_connection(host:, port:)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(failover_adapter_config(host: host, port: port))
  end

  # Queries the current instance id through ActiveRecord (as an application would), rather than
  # through the raw-driver dialect path used by rds_util.query_instance_id.
  def current_instance_id
    ActiveRecord::Base.connection.select_value(
      Integration::RdsTestUtility.instance_id_query(env.engine)
    ).to_s
  end

  after do
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  describe 'writer failover' do
    it 'raises FailoverSuccessError on query then serves the next query from the new writer',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      establish_failover_connection(host: proxy_info.cluster_endpoint, port: proxy_info.cluster_endpoint_port)
      # Prime the pool so the connection is open before the writer is crashed.
      expect(ActiveRecord::Base.connection.select_value('SELECT 1').to_i).to eq(1)

      rds_util.crash_instance(current_writer)

      # The adapter re-raises FailoverSuccessError so the caller learns the in-flight query was lost.
      expect { current_instance_id }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      # The connection is now reconfigured against the new topology and usable again.
      new_writer_id = current_instance_id
      expect(Integration::RetryHelper.verify_writer(rds_util, new_writer_id)).to be true
    end

    it 'reconfigures the connection after it is returned to the pool and checked back out',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      establish_failover_connection(host: proxy_info.cluster_endpoint, port: proxy_info.cluster_endpoint_port)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1').to_i).to eq(1)

      rds_util.crash_instance(current_writer)

      expect { current_instance_id }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      # Returning the connection and checking it back out triggers verify! -> configure_connection
      # against the new writer. with_connection yields a healthy, reconfigured connection.
      ActiveRecord::Base.connection_pool.with_connection do
        new_writer_id = ActiveRecord::Base.connection.select_value(
          Integration::RdsTestUtility.instance_id_query(env.engine)
        ).to_s
        expect(Integration::RetryHelper.verify_writer(rds_util, new_writer_id)).to be true
      end
    end

    it 'rolls back the open transaction when failover happens mid-transaction',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      establish_failover_connection(host: initial_writer_instance.host, port: initial_writer_instance.port)

      conn = ActiveRecord::Base.connection
      conn.execute('DROP TABLE IF EXISTS ar_test_failover_transaction')
      conn.execute(
        'CREATE TABLE ar_test_failover_transaction (id int not null primary key, val varchar(255) not null)'
      )

      expect do
        conn.transaction do
          conn.execute("INSERT INTO ar_test_failover_transaction VALUES (1, 'value1')")
          rds_util.crash_instance(current_writer)
          conn.execute("INSERT INTO ar_test_failover_transaction VALUES (2, 'value2')")
        end
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError)

      # After failover the connection is reconfigured against the new writer; the aborted
      # transaction must not have committed any rows.
      new_writer_id = current_instance_id
      expect(Integration::RetryHelper.verify_writer(rds_util, new_writer_id)).to be true

      count = ActiveRecord::Base.connection.select_value(
        'SELECT count(*) FROM ar_test_failover_transaction'
      ).to_i
      expect(count).to eq(0)

      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS ar_test_failover_transaction')
    end
  end

  describe 'failover failure' do
    it 'raises ActiveRecord::ConnectionFailed when all instances are unreachable',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      initial_writer_instance = proxy_info.instances.first
      config = failover_adapter_config(host: initial_writer_instance.host, port: initial_writer_instance.port)
      config[AwsRubyDatabaseDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.name] = 30

      ActiveRecord::Base.connection_handler.clear_all_connections!
      ActiveRecord::Base.establish_connection(config)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1').to_i).to eq(1)

      Integration::ProxyHelper.disable_all_connectivity

      expect { current_instance_id }.to raise_error(ActiveRecord::ConnectionFailed)
    end
  end

  describe 'reader failover' do
    it 'fails over from reader to writer when no other reader available',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2, max_instances: 2)

      reader_instance = proxy_info.instances[1]
      establish_failover_connection(host: reader_instance.host, port: reader_instance.port)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1').to_i).to eq(1)

      Integration::ProxyHelper.disable_connectivity(reader_instance.instance_id)

      expect { current_instance_id }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      new_connection_id = current_instance_id
      expect(new_connection_id).to eq(current_writer)
      expect(Integration::RetryHelper.verify_writer(rds_util, new_connection_id)).to be true
    end
  end
end
