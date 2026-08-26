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

require 'rspec'
require 'aws_advanced_ruby_driver_wrapper/utils/connection_config_parser'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::ConnectionConfigParser do
  let(:parser) { described_class }

  describe 'URI parsing' do
    it 'parses a PostgreSQL URI with host, port, user, password, and dbname' do
      config = parser.parse(:postgresql, 'postgresql://myuser:mypass@myhost:5432/mydb')
      expect(config.driver_name).to eq(:postgresql)
      expect(config.driver_props[:host]).to eq('myhost')
      expect(config.driver_props[:port]).to eq('5432')
      expect(config.driver_props[:user]).to eq('myuser')
      expect(config.driver_props[:password]).to eq('mypass')
      expect(config.driver_props[:dbname]).to eq('mydb')
    end

    it 'parses multi-host PG URIs' do
      config = parser.parse(:postgresql, 'postgresql://user:pass@host1,host2:5433/mydb')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('-1,5433')
      expect(config.driver_props[:host]).to eq('host1,host2')
      expect(config.driver_props[:port]).to eq(',5433')
    end

    it 'parses multi-host URIs with per-host ports' do
      config = parser.parse(:postgresql, 'postgresql://host1:5432,host2:5433/db')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5432,5433')
      expect(config.driver_props[:host]).to eq('host1,host2')
      expect(config.driver_props[:port]).to eq('5432,5433')
    end

    it 'parses multi-host URIs with no ports' do
      config = parser.parse(:postgresql, 'postgresql://host1,host2/db')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('-1')
      expect(config.driver_props[:host]).to eq('host1,host2')
      expect(config.driver_props.key?(:port)).to be false
    end

    it 'parses multi-host URIs with mixed ports (only first host has port)' do
      config = parser.parse(:postgresql, 'postgresql://host1:5433,host2/db')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5433,-1')
      expect(config.driver_props.key?(:'host1,host2')).to be false
      expect(config.driver_props.key?(:'5433,')).to be false
    end

    it 'extracts wrapper properties from query params into wrapper_config' do
      config = parser.parse(:postgresql, 'postgresql://host/db?wrapper_plugins=failover&cluster_id=test')
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
      expect(config.wrapper_props[:cluster_id]).to eq('test')
    end

    it 'keeps non-wrapper query params in driver_config' do
      config = parser.parse(:postgresql, 'postgresql://host/db?sslmode=require&wrapper_plugins=failover')
      expect(config.driver_props[:sslmode]).to eq('require')
      expect(config.driver_props.key?(:wrapper_plugins)).to be false
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
    end

    it 'handles URI with no query params' do
      config = parser.parse(:postgresql, 'postgresql://host/db')
      expect(config.wrapper_props).to be_empty
      expect(config.driver_props[:host]).to eq('host')
      expect(config.driver_props.key?(:port)).to be false
    end

    it 'handles URI with no database' do
      config = parser.parse(:postgresql, 'postgresql://host:5432')
      expect(config.driver_props[:host]).to eq('host')
      expect(config.driver_props[:port]).to eq('5432')
      expect(config.driver_props.key?(:dbname)).to be false
    end

    it 'URL-decodes user and password' do
      config = parser.parse(:postgresql, 'postgresql://my%40user:p%40ss@host/db')
      expect(config.driver_props[:user]).to eq('my@user')
      expect(config.driver_props[:password]).to eq('p@ss')
    end

    it 'keyword overrides win over URI query params' do
      config = parser.parse(:postgresql,
                            'postgresql://host/db?wrapper_plugins=iam',
                            wrapper_plugins: 'failover')
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
    end

    it 'parses single-host URI initial_host_info' do
      config = parser.parse(:postgresql, 'postgresql://myhost:5432/mydb')
      expect(config.initial_host_info.host).to eq('myhost')
      expect(config.initial_host_info.port).to eq('5432')
    end

    it 'parses single-host URI without port' do
      config = parser.parse(:postgresql, 'postgresql://myhost/mydb')
      expect(config.initial_host_info.host).to eq('myhost')
      expect(config.initial_host_info.port).to eq('-1')
      expect(config.driver_props.key?(:port)).to be false
    end

    it 'parses three-host URI with all ports' do
      config = parser.parse(:postgresql, 'postgresql://h1:5432,h2:5433,h3:5434/db')
      expect(config.initial_host_info.host).to eq('h1,h2,h3')
      expect(config.initial_host_info.port).to eq('5432,5433,5434')
      expect(config.driver_props[:host]).to eq('h1,h2,h3')
      expect(config.driver_props[:port]).to eq('5432,5433,5434')
    end
  end

  describe 'hash parsing' do
    it 'parses keyword arguments' do
      config = parser.parse(:postgresql, host: 'myhost', dbname: 'mydb', port: 5432)
      expect(config.driver_props[:host]).to eq('myhost')
      expect(config.driver_props[:dbname]).to eq('mydb')
      expect(config.driver_props[:port]).to eq('5432')
    end

    it 'splits wrapper properties from driver properties' do
      config = parser.parse(:postgresql, host: 'myhost', wrapper_plugins: 'failover', cluster_id: 'prod')
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
      expect(config.wrapper_props[:cluster_id]).to eq('prod')
      expect(config.driver_props.key?(:wrapper_plugins)).to be false
      expect(config.driver_props.key?(:cluster_id)).to be false
      expect(config.driver_props[:host]).to eq('myhost')
    end

    it 'parses a hash passed as a positional argument' do
      config = parser.parse(:postgresql, { host: 'myhost', dbname: 'mydb', cluster_id: 'test' })
      expect(config.driver_props[:host]).to eq('myhost')
      expect(config.wrapper_props[:cluster_id]).to eq('test')
    end

    it 'stores the provided driver_name' do
      pg = parser.parse(:postgresql, host: 'h')
      mysql = parser.parse(:mysql2, host: 'h')
      expect(pg.driver_name).to eq(:postgresql)
      expect(mysql.driver_name).to eq(:mysql2)
    end

    it 'parses initial_host_info from hash' do
      config = parser.parse(:postgresql, host: 'myhost', port: 5432)
      expect(config.initial_host_info.host).to eq('myhost')
      expect(config.initial_host_info.port).to eq('5432')
    end

    it 'parses comma-separated hosts from hash' do
      config = parser.parse(:postgresql, host: 'host1,host2', port: 5433)
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5433')
      expect(config.driver_props[:host]).to eq('host1,host2')
    end

    it 'parses per-host ports from hash' do
      config = parser.parse(:postgresql, host: 'host1,host2', port: '5432,5433')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5432,5433')
      expect(config.driver_props[:host]).to eq('host1,host2')
      expect(config.driver_props[:port]).to eq('5432,5433')
    end

    it 'does not leak wrapper properties into driver_config' do
      config = parser.parse(:postgresql,
                            host: 'myhost',
                            wrapper_plugins: 'failover',
                            cluster_id: 'no-leak',
                            failover_timeout_sec: 60)
      expect(config.driver_props.key?(:wrapper_plugins)).to be false
      expect(config.driver_props.key?(:cluster_id)).to be false
      expect(config.driver_props.key?(:failover_timeout_sec)).to be false
    end

    it 'handles a single port across multiple hosts (integer port)' do
      config = parser.parse(:postgresql, host: 'host1,host2,host3', port: 5432)
      expect(config.initial_host_info.host).to eq('host1,host2,host3')
      expect(config.initial_host_info.port).to eq('5432')
      expect(config.driver_props[:host]).to eq('host1,host2,host3')
      expect(config.driver_props[:port]).to eq('5432')
    end

    it 'handles a single port across multiple hosts (string port)' do
      config = parser.parse(:postgresql, host: 'host1,host2', port: '5433')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5433')
    end

    it 'uses NO_PORT for multiple hosts with no port specified' do
      config = parser.parse(:postgresql, host: 'host1,host2')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('-1')
    end

    it 'uses NO_PORT for a single host with no port specified' do
      config = parser.parse(:postgresql, host: 'myhost')
      expect(config.initial_host_info.host).to eq('myhost')
      expect(config.initial_host_info.port).to eq('-1')
    end

    it 'handles nil host with port specified' do
      config = parser.parse(:postgresql, host: nil, port: 5433, user: 'u', password: 'p')
      expect(config.initial_host_info).not_to be_nil
      expect(config.initial_host_info.host_specified?).to be false
      expect(config.initial_host_info.port_specified?).to be true
      expect(config.initial_host_info.port).to eq('5433')
    end

    it 'handles empty string host' do
      config = parser.parse(:postgresql, host: '', port: 5432, user: 'u', password: 'p')
      expect(config.initial_host_info).not_to be_nil
      expect(config.initial_host_info.host_specified?).to be false
    end

    it 'handles nil host and nil port (Unix socket defaults)' do
      config = parser.parse(:postgresql, host: nil, user: 'u', password: 'p')
      expect(config.initial_host_info).not_to be_nil
      expect(config.initial_host_info.host_specified?).to be false
      expect(config.initial_host_info.port_specified?).to be false
    end

    it 'handles only user/password with no host or port' do
      config = parser.parse(:postgresql, user: 'u', password: 'p', dbname: 'mydb')
      expect(config.initial_host_info).not_to be_nil
      expect(config.initial_host_info.host_specified?).to be false
      expect(config.initial_host_info.port_specified?).to be false
      expect(config.driver_props[:user]).to eq('u')
      expect(config.driver_props[:dbname]).to eq('mydb')
    end
  end

  describe 'PG positional argument parsing' do
    it 'parses host, port, options, tty, dbname, user, password' do
      config = parser.parse(:postgresql, 'myhost', 5432, nil, nil, 'mydb', 'user', 'pass')
      expect(config.driver_name).to eq(:postgresql)
      expect(config.driver_props[:host]).to eq('myhost')
      expect(config.driver_props[:port]).to eq('5432')
      expect(config.driver_props[:dbname]).to eq('mydb')
      expect(config.driver_props[:user]).to eq('user')
      expect(config.driver_props[:password]).to eq('pass')
    end

    it 'accepts wrapper config as keyword alongside positional args' do
      config = parser.parse(:postgresql, 'myhost', 5432, nil, nil, 'mydb', cluster_id: 'test')
      expect(config.wrapper_props[:cluster_id]).to eq('test')
      expect(config.driver_props[:host]).to eq('myhost')
    end
  end

  describe 'PG conninfo string parsing' do
    it 'parses a basic conninfo string' do
      config = parser.parse(:postgresql, 'host=localhost port=5432 dbname=mydb user=myuser password=mypass')
      expect(config.driver_props[:host]).to eq('localhost')
      expect(config.driver_props[:port]).to eq('5432')
      expect(config.driver_props[:dbname]).to eq('mydb')
      expect(config.driver_props[:user]).to eq('myuser')
      expect(config.driver_props[:password]).to eq('mypass')
      expect(config.initial_host_info.host).to eq('localhost')
      expect(config.initial_host_info.port).to eq('5432')
    end

    it 'parses multi-host conninfo with per-host ports' do
      config = parser.parse(:postgresql, 'host=host1,host2 port=5432,5433 dbname=mydb')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5432,5433')
      expect(config.driver_props[:host]).to eq('host1,host2')
      expect(config.driver_props[:port]).to eq('5432,5433')
    end

    it 'extracts wrapper properties from conninfo' do
      config = parser.parse(:postgresql, 'host=localhost port=5432 dbname=mydb cluster_id=test')
      expect(config.wrapper_props[:cluster_id]).to eq('test')
      expect(config.driver_props.key?(:cluster_id)).to be false
    end

    it 'handles single-quoted values with spaces' do
      config = parser.parse(:postgresql, "host=localhost password='has spaces' dbname=mydb")
      expect(config.driver_props[:password]).to eq('has spaces')
    end

    it 'accepts keyword overrides alongside conninfo' do
      config = parser.parse(:postgresql, 'host=localhost dbname=mydb', cluster_id: 'override')
      expect(config.driver_props[:host]).to eq('localhost')
      expect(config.wrapper_props[:cluster_id]).to eq('override')
    end

    it 'parses multi-host conninfo with single port applied to all hosts' do
      config = parser.parse(:postgresql, 'host=host1,host2 port=5433 dbname=mydb')
      expect(config.initial_host_info.host).to eq('host1,host2')
      expect(config.initial_host_info.port).to eq('5433')
      expect(config.driver_props[:host]).to eq('host1,host2')
      expect(config.driver_props[:port]).to eq('5433')
    end
  end

  describe 'no type coercion at parse time' do
    it 'leaves string values as strings from URI query params' do
      config = parser.parse(:postgresql, 'postgresql://host/db?failover_timeout_sec=120')
      # Values stay as strings — coercion happens at read time via WrapperProperty getters
      expect(config.wrapper_props[:failover_timeout_sec]).to eq('120')
    end

    it 'preserves native types from hash input' do
      config = parser.parse(:postgresql, host: 'h', failover_timeout_sec: 120)
      expect(config.wrapper_props[:failover_timeout_sec]).to eq(120)
    end
  end

  describe 'driver_name' do
    it 'uses the protocol provided by the caller' do
      config = parser.parse(:postgresql, 'mysql2://host/db')
      expect(config.driver_name).to eq(:postgresql)
    end

    it 'uses :mysql2 when provided' do
      config = parser.parse(:mysql2, host: 'myhost')
      expect(config.driver_name).to eq(:mysql2)
    end
  end

  describe 'original_host and original_port' do
    it 'extracts from a single-host URI with port' do
      config = parser.parse(:postgresql, 'postgresql://host:5432/db')
      expect(config.original_host).to eq('host')
      expect(config.original_port).to eq('5432')
    end

    it 'extracts from a single-host URI without port' do
      config = parser.parse(:postgresql, 'postgresql://host/db')
      expect(config.original_host).to eq('host')
      expect(config.original_port).to eq('')
    end

    it 'extracts from a multi-host URI with mixed ports' do
      config = parser.parse(:postgresql, 'postgresql://host1,host2:5433/db')
      expect(config.original_host).to eq('host1,host2')
      expect(config.original_port).to eq(',5433')
    end

    it 'extracts from a multi-host URI with all ports' do
      config = parser.parse(:postgresql, 'postgresql://host1:5432,host2:5433/db')
      expect(config.original_host).to eq('host1,host2')
      expect(config.original_port).to eq('5432,5433')
    end

    it 'extracts from a multi-host URI with no ports' do
      config = parser.parse(:postgresql, 'postgresql://host1,host2/db')
      expect(config.original_host).to eq('host1,host2')
      expect(config.original_port).to eq(',')
    end

    it 'extracts from keyword arguments' do
      config = parser.parse(:postgresql, host: 'host1,host2', port: '5432,5433')
      expect(config.original_host).to eq('host1,host2')
      expect(config.original_port).to eq('5432,5433')
    end

    it 'extracts from keyword arguments with single port' do
      config = parser.parse(:postgresql, host: 'host1,host2', port: 5433)
      expect(config.original_host).to eq('host1,host2')
      expect(config.original_port).to eq('5433')
    end

    it 'extracts from a conninfo string' do
      config = parser.parse(:postgresql, 'host=host1,host2 port=5432,5433')
      expect(config.original_host).to eq('host1,host2')
      expect(config.original_port).to eq('5432,5433')
    end

    it 'extracts from positional arguments' do
      config = parser.parse(:postgresql, 'myhost', 5432)
      expect(config.original_host).to eq('myhost')
      expect(config.original_port).to eq('5432')
    end
  end

  describe 'type validation' do
    context 'wrapper props' do
      it 'accepts a valid type' do
        expect { parser.parse(:postgresql, host: 'h', cluster_id: 'my-cluster') }.not_to raise_error
      end

      it 'accepts a string integer for an Integer-typed property' do
        expect { parser.parse(:postgresql, host: 'h', failover_timeout_sec: '120') }.not_to raise_error
      end

      it 'raises TypeError for a wrong type' do
        expect do
          parser.parse(:postgresql, host: 'h', failover_timeout_sec: [120])
        end.to raise_error(TypeError, /failover_timeout_sec/)
      end

      it 'allows nil values regardless of type' do
        expect { parser.parse(:postgresql, host: 'h', cluster_id: nil) }.not_to raise_error
      end

      it 'ignores unknown wrapper keys' do
        expect { parser.parse(:postgresql, host: 'h', unknown_prop: 123) }.not_to raise_error
      end
    end

    context 'prefixed props' do
      it 'accepts a valid type in prefixed props' do
        expect { parser.parse(:postgresql, host: 'h', topology_monitoring_failover_timeout_sec: 60) }.not_to raise_error
      end

      it 'accepts a string integer for an Integer-typed prefixed property' do
        expect { parser.parse(:postgresql, host: 'h', topology_monitoring_failover_timeout_sec: '60') }.not_to raise_error
      end

      it 'raises TypeError for a wrong type in prefixed props' do
        expect do
          parser.parse(:postgresql, host: 'h', topology_monitoring_failover_timeout_sec: [60])
        end.to raise_error(TypeError, /failover_timeout_sec/)
      end

      it 'ignores unknown prefixed keys' do
        expect { parser.parse(:postgresql, host: 'h', topology_monitoring_unknown_prop: 123) }.not_to raise_error
      end
    end
  end

  describe 'validator enforcement at parse time' do
    it 'raises ArgumentError for a negative POSITIVE_INTEGER prop' do
      expect do
        parser.parse(:postgresql, host: 'h', failover_timeout_sec: -1)
      end.to raise_error(ArgumentError, /failover_timeout_sec.*-1/)
    end

    it 'raises ArgumentError for zero on a POSITIVE_INTEGER prop' do
      expect do
        parser.parse(:postgresql, host: 'h', failover_timeout_sec: 0)
      end.to raise_error(ArgumentError, /failover_timeout_sec.*0/)
    end

    it 'raises ArgumentError for a negative NON_NEGATIVE_INTEGER prop' do
      expect do
        parser.parse(:postgresql, host: 'h', secret_rotation_retry_timeout_ms: -1)
      end.to raise_error(ArgumentError, /secret_rotation_retry_timeout_ms.*-1/)
    end

    it 'does not raise for zero on a NON_NEGATIVE_INTEGER prop' do
      expect { parser.parse(:postgresql, host: 'h', secret_rotation_retry_timeout_ms: 0) }.not_to raise_error
    end

    it 'raises ArgumentError for a negative prefixed POSITIVE_INTEGER prop' do
      expect do
        parser.parse(:postgresql, host: 'h', topology_monitoring_failover_timeout_sec: -5)
      end.to raise_error(ArgumentError, /failover_timeout_sec.*-5/)
    end

    it 'does not run the validator on get after a valid parse' do
      config = parser.parse(:postgresql, host: 'h', failover_timeout_sec: 60)
      expect { AwsAdvancedRubyDriverWrapper::PropertyDefinition::FAILOVER_TIMEOUT_SEC.get(config.wrapper_props) }.not_to raise_error
    end
  end

  describe 'multi_host?' do
    it 'returns true for multi-host URI' do
      config = parser.parse(:postgresql, 'postgresql://host1,host2:5433/mydb')
      expect(config.multi_host_url?).to be true
    end

    it 'returns false for single-host URI' do
      config = parser.parse(:postgresql, 'postgresql://myhost:5432/mydb')
      expect(config.multi_host_url?).to be false
    end

    it 'returns true for comma-separated hosts in hash' do
      config = parser.parse(:postgresql, host: 'host1,host2', port: 5433)
      expect(config.multi_host_url?).to be true
    end

    it 'returns false for single host in hash' do
      config = parser.parse(:postgresql, host: 'myhost', port: 5432)
      expect(config.multi_host_url?).to be false
    end

    it 'returns true for multi-host conninfo string' do
      config = parser.parse(:postgresql, 'host=host1,host2 port=5432,5433')
      expect(config.multi_host_url?).to be true
    end

    it 'returns false for single-host conninfo string' do
      config = parser.parse(:postgresql, 'host=localhost port=5432')
      expect(config.multi_host_url?).to be false
    end
  end
end
