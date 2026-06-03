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

module ActiveRecordAdapterHelper
  # Resets the quoted_table_name cache on a list of model classes.
  # This is necessary when switching between PG and MySQL adapters in the same process
  # because AR 7.2 caches quoted_table_name using adapter_class.quote_table_name.
  def self.reset_table_name_cache(model_classes)
    model_classes.each { |klass| klass.instance_variable_set(:@quoted_table_name, nil) }
  end

  # Establishes a fresh connection for the given driver_helper config,
  # clearing all previous connections and resetting model caches.
  def self.establish_fresh_connection(driver_helper, model_classes)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(driver_helper.adapter_config)
    reset_table_name_cache(model_classes)
  end

  # Returns the expected adapter name for the given driver_helper config.
  def self.expected_adapter_name(driver_helper)
    driver_helper.adapter_config[:adapter].include?('mysql') ? 'AwsMySQL2' : 'AwsPostgreSQL'
  end

  # Ensures the correct adapter is active. Only reconnects if the adapter has been
  # switched by another test context (avoids expensive reconnections when unnecessary).
  def self.ensure_correct_adapter(driver_helper, model_classes)
    return if ActiveRecord::Base.connection.adapter_name == expected_adapter_name(driver_helper)

    establish_fresh_connection(driver_helper, model_classes)
  end
end
