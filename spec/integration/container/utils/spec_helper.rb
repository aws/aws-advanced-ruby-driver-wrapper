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
#  limitations under the License.require 'rspec'

RSpec.shared_context 'integration setup' do
  let(:env)      { Integration::TestEnvironment.current }
  let(:info)     { env.database_info }
  let(:writer)   { info.instances.first }
  let(:drv)      { env.current_driver || env.allowed_test_drivers.first }

  let(:base_config) do
    Integration::DriverHelper.native_config(
      drv,
      host: writer.host,
      port: writer.port,
      user: info.username,
      password: info.password,
      dbname: info.default_dbname
    )
  end
  let(:proxy_config) do
    proxy_instance = env.proxy_database_info.instances.first
    config = Integration::DriverHelper.native_config(
      drv,
      host: proxy_instance.host,
      port: proxy_instance.port,
      user: info.username,
      password: info.password,
      dbname: env.proxy_database_info.default_dbname
    )
    case drv
    when Integration::TestDriver::PG
      ssl = env.deployment == Integration::DatabaseEngineDeployment::AURORA ? { sslmode: 'require' } : {}
      config.merge(connect_timeout: 3, **ssl)
    when Integration::TestDriver::MYSQL
      config.merge(connect_timeout: 3, read_timeout: 3, write_timeout: 3)
    else
      config
    end
  end

  before(:each) do |example|
    driver = example.metadata[:test_driver]
    Integration::IntegrationHelper.setup_test(
      current_driver: driver,
      test_name: example.full_description
    )
  end
end

RSpec.configure do |config|
  config.include_context 'integration setup', :integration
  config.include Integration::ConditionChecker, :integration

  config.before(:each, :integration) do |example|
    if (deployments = example.metadata[:deployments])
      enable_on_deployments(*deployments)
    end
    if (deployments = example.metadata[:require_deployments])
      require_deployments(*deployments)
    end
    if (features = example.metadata[:features])
      enable_on_features(*features)
    end
    if (engines = example.metadata[:enable_on_engines])
      enable_on_engines(*engines)
    end
    if (engines = example.metadata[:disable_on_engines])
      disable_on_engines(*engines)
    end
    if (features = example.metadata[:disable_on_features])
      disable_on_features(*features)
    end
  end

  # Parameterise by allowed test drivers. Tag specs with :parameterize_drivers
  # and iterate over allowed_test_drivers in shared examples.
  config.before(:each, :parameterize_drivers) do
    env = Integration::TestEnvironment.current
    skip 'No allowed drivers for this environment' if env.allowed_test_drivers.empty?
  end
end
