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
#   * #verify! runs configure_connection against the new physical connection once @needs_reconfiguration is set.
RSpec.describe 'Failover (ActiveRecord)', :integration,
               features: [Integration::TestEnvironmentFeatures::FAILOVER_SUPPORTED],
               deployments: [Integration::DatabaseEngineDeployment::AURORA],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:rds_util) { Integration::RdsTestUtility.utility }
  let(:proxy_info) { env.proxy_database_info }
  let(:current_writer) { proxy_info.instances.first.instance_id }

  # AR connection config pointing at the cluster/instance endpoints through the proxy, with the
  # failover plugin enabled. Wrapper property keys pass through the adapter into the wrapper unchanged.
  # An optional :variables hash is applied by AR's configure_connection via SET SESSION statements.
  def failover_adapter_config(host:, port:, variables: nil)
    adapter = case drv
              when Integration::TestDriver::PG    then 'aws_postgresql'
              when Integration::TestDriver::MYSQL then 'aws_mysql2'
              else raise "Unsupported driver: #{drv}"
              end

    config = {
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
    config[:variables] = variables if variables
    config
  end

  # A per-engine session variable that AR applies via configure_connection (:variables), whose value
  # echoes back verbatim and whose default differs from the probe value. A brand-new connection after
  # failover starts at the server default, so if the probe value survives, configure_connection must
  # have re-applied it. The failover plugin does not restore arbitrary session variables itself, so
  # this isolates the AR adapter's reconfiguration behavior.
  def session_probe
    case drv
    when Integration::TestDriver::PG
      { name: :application_name, value: 'ar_failover_probe',
        read_sql: "SELECT current_setting('application_name')", expected: 'ar_failover_probe' }
    when Integration::TestDriver::MYSQL
      { name: :group_concat_max_len, value: 12_345,
        read_sql: 'SELECT @@SESSION.group_concat_max_len', expected: 12_345 }
    else
      raise "Unsupported driver: #{drv}"
    end
  end

  def establish_failover_connection(host:, port:, variables: nil)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(
      failover_adapter_config(host: host, port: port, variables: variables)
    )
  end

  # The physical driver connection (PG::Connection / Mysql2::Client) currently held inside the
  # wrapper. Reaches into wrapper internals; used only to prove the failover swap actually replaced it.
  def physical_connection(wrapper)
    wrapper.instance_variable_get(:@service_container).connection_service.current_connection
  end

  # Queries the current instance id through ActiveRecord (as an application would), rather than
  # through the raw-driver dialect path used by rds_util.query_instance_id.
  def current_instance_id
    instance_id_via(ActiveRecord::Base.connection)
  end

  # Queries the current instance id through a specific connection. Use this inside with_connection
  # blocks so the query runs on the yielded connection rather than taking a sticky lease via
  # ActiveRecord::Base.connection.
  def instance_id_via(conn)
    conn.select_value(Integration::RdsTestUtility.instance_id_query(env.engine)).to_s
  end

  after do
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  describe 'writer failover' do
    it 'raises FailoverSuccessError, then recovers on the same wrapper with session state restored',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      probe = session_probe
      establish_failover_connection(
        host: proxy_info.cluster_endpoint,
        port: proxy_info.cluster_endpoint_port,
        variables: { probe[:name] => probe[:value] }
      )
      adapter = ActiveRecord::Base.connection
      # Prime the pool so the connection is open before the writer is crashed.
      expect(adapter.select_value('SELECT 1').to_i).to eq(1)
      # The probe variable is applied by configure_connection on the initial connect.
      expect(adapter.select_value(probe[:read_sql])).to eq(probe[:expected])

      # The wrapper object AR holds as its raw connection. The failover plugin swaps the physical
      # connection *inside* this object, so its identity should be unchanged across failover. Read
      # the ivar directly rather than #raw_connection, which would trigger verify!/reconnect.
      wrapper_before = adapter.instance_variable_get(:@raw_connection)
      physical_before = physical_connection(wrapper_before)

      rds_util.crash_instance(current_writer)

      # The adapter re-raises FailoverSuccessError so the caller learns the in-flight query was lost.
      expect { current_instance_id }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      # The next query on the same leased connection reaches the new writer: the failover plugin has
      # already swapped the physical connection inside the wrapper object.
      new_writer_id = current_instance_id
      expect(Integration::RetryHelper.verify_writer(rds_util, new_writer_id)).to be true

      # AR still holds the exact same wrapper object; only the physical connection underneath changed.
      wrapper_after = adapter.instance_variable_get(:@raw_connection)
      expect(wrapper_after).to be(wrapper_before)

      # ...and the physical driver connection inside the wrapper was genuinely swapped by failover.
      expect(physical_connection(wrapper_after)).not_to be(physical_before)

      # The probe variable survives on the brand-new physical connection, which starts at the server
      # default. Since the failover plugin does not restore arbitrary session variables itself, this is
      # end-to-end proof that the adapter's configure_connection re-applied session state after failover.
      expect(adapter.select_value(probe[:read_sql])).to eq(probe[:expected])
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

    it 'recovers on a fresh pool checkout after failover (Rails request-cycle pattern)',
       features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
      enable_on_num_instances(min_instances: 2)

      probe = session_probe
      establish_failover_connection(
        host: proxy_info.cluster_endpoint,
        port: proxy_info.cluster_endpoint_port,
        variables: { probe[:name] => probe[:value] }
      )
      pool = ActiveRecord::Base.connection_pool

      # This test models a pooled app (e.g. a Rails web app) that checks a connection out per unit of
      # work and checks it back in, rather than holding one connection. We must never call
      # ActiveRecord::Base.connection here: that would take a sticky lease and turn the second
      # with_connection into a no-op re-yield, bypassing the checkout/verify path we want to exercise.

      # First checkout: prime the connection and confirm the probe variable is set.
      pool.with_connection do |conn|
        expect(conn.select_value('SELECT 1').to_i).to eq(1)
        expect(conn.select_value(probe[:read_sql])).to eq(probe[:expected])
        rds_util.crash_instance(current_writer)
        expect { instance_id_via(conn) }.to raise_error(
          AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
        )
      end

      # Second checkout: checkout_and_verify -> clean! resets @verified, so the next query re-verifies
      # and reconfigures. The app-facing contract is a healthy connection with session state restored.
      pool.with_connection do |conn|
        new_writer_id = instance_id_via(conn)
        expect(Integration::RetryHelper.verify_writer(rds_util, new_writer_id)).to be true
        expect(conn.select_value(probe[:read_sql])).to eq(probe[:expected])
      end
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

      probe = session_probe
      reader_instance = proxy_info.instances[1]
      establish_failover_connection(
        host: reader_instance.host,
        port: reader_instance.port,
        variables: { probe[:name] => probe[:value] }
      )
      adapter = ActiveRecord::Base.connection
      expect(adapter.select_value('SELECT 1').to_i).to eq(1)
      # Session variables are applied via SET SESSION, so they set fine on a reader connection too.
      expect(adapter.select_value(probe[:read_sql])).to eq(probe[:expected])

      Integration::ProxyHelper.disable_connectivity(reader_instance.instance_id)

      expect { current_instance_id }.to raise_error(
        AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError
      )

      new_connection_id = current_instance_id
      expect(new_connection_id).to eq(current_writer)
      expect(Integration::RetryHelper.verify_writer(rds_util, new_connection_id)).to be true

      # configure_connection re-applies session state onto the new writer connection after reader failover.
      expect(adapter.select_value(probe[:read_sql])).to eq(probe[:expected])
    end
  end
end
