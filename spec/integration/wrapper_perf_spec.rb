# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require 'benchmark'

def analyze_times(iterations, times, conn_type, workflow_name)
  total_time = times.sum
  avg_time = total_time / iterations
  min_time = times.min
  max_time = times.max
  median_time = times.sort[iterations / 2]

  puts "\n#{'=' * 60}"
  puts "Performance Results for #{workflow_name} with #{conn_type} connection:"
  puts '=' * 60
  puts "Iterations: #{iterations}"
  puts "Total time: #{(total_time * 1000).round(2)}ms"
  puts "Average time: #{(avg_time * 1000).round(2)}ms"
  puts "Median time: #{(median_time * 1000).round(2)}ms"
  puts "Min time: #{(min_time * 1000).round(2)}ms"
  puts "Max time: #{(max_time * 1000).round(2)}ms"
  puts '=' * 60

  expect(total_time).to be > 0
  expect(avg_time).to be > 0
end

def gather_metrics(wrapper_func, wrapper_args, vanilla_func, vanilla_args, iterations, workflow_name)
  wrapper_times = []
  vanilla_times = []

  iterations.times do
    wrapper_elapsed = Benchmark.realtime do
      wrapper_func.call(*wrapper_args)
    end
    wrapper_times << wrapper_elapsed

    vanilla_elapsed = Benchmark.realtime do
      vanilla_func.call(*vanilla_args)
    end

    vanilla_times << vanilla_elapsed
  end

  analyze_times(iterations, wrapper_times, 'wrapper', workflow_name)
  analyze_times(iterations, vanilla_times, 'vanilla', workflow_name)
end

RSpec.shared_examples 'Plugin pipeline benchmarks' do |driver_helper|
  include driver_helper

  it 'execute performance is comparable between wrapped and vanilla drivers' do
    @wrapper_conn = driver_helper.wrapper_connect
    @vanilla_conn = driver_helper.native_connect
    target_func = ->(conn) { conn.exec('SELECT 1') }
    gather_metrics(target_func, [@wrapper_conn], target_func, [@vanilla_conn], 1000, 'execute')
  end

  # TODO: only PG has this 'prepare' signature, so we will need to adjust this so that it works for MySQL too.
  it 'method_missing performance is comparable between wrapped and vanilla drivers' do
    @wrapper_conn = driver_helper.wrapper_connect
    @wrapper_conn.prepare('get_employee', 'SELECT $1')
    @vanilla_conn = driver_helper.native_connect
    @vanilla_conn.prepare('get_employee', 'SELECT $1')
    target_func = ->(conn) { conn.describe_prepared('get_employee') }
    gather_metrics(target_func, [@wrapper_conn], target_func, [@vanilla_conn], 1000, 'method_missing')
  end

  it 'connect performance is comparable between wrapped and vanilla drivers' do
    wrapper_func = lambda {
      conn = driver_helper.wrapper_connect
      conn&.close
    }

    vanilla_func = lambda {
      conn = driver_helper.native_connect
      conn&.close
    }
    gather_metrics(wrapper_func, [], vanilla_func, [], 100, 'connect')
  end

  it 'connect + execute performance is comparable between wrapped and vanilla drivers' do
    wrapper_func = lambda {
      conn = driver_helper.wrapper_connect
      conn.exec('SELECT 1')
      conn&.close
    }

    vanilla_func = lambda {
      conn = driver_helper.native_connect
      conn.exec('SELECT 1')
      conn&.close
    }
    gather_metrics(wrapper_func, [], vanilla_func, [], 100, 'connect + execute')
  end
end

RSpec.describe 'Plugin pipeline benchmarks' do
  context 'PostgreSQL' do
    include_examples 'Plugin pipeline benchmarks', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'Plugin pipeline benchmarks', MysqlTestHelper
  end
end
