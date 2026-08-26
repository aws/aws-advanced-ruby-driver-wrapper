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
require_relative 'utils/blue_green_spec_orchestrator'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/database_engine_deployment'
require_relative 'utils/rds_test_utility'
require_relative 'utils/driver_helper'
require 'aws_ruby_driver_wrapper'

RSpec.describe 'BlueGreenDeployment', :integration, :blue_green,
               features: [Integration::TestEnvironmentFeatures::BLUE_GREEN_DEPLOYMENT],
               deployments: [Integration::DatabaseEngineDeployment::AURORA,
                             Integration::DatabaseEngineDeployment::RDS_MULTI_AZ_INSTANCE],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  before(:all) do
    @env = Integration::TestEnvironment.current
    @driver = @env.allowed_test_drivers.first
    @iam_enabled = @env.features.include?(Integration::TestEnvironmentFeatures::IAM)
    @rds_utility = Integration::RdsTestUtility.utility

    @orchestrator = Integration::BlueGreenSpecOrchestrator.new(
      env: @env, driver: @driver, rds_utility: @rds_utility, iam_enabled: @iam_enabled
    )
    @orchestrator.run
    @global = @orchestrator.global_results
    @captured_log = @orchestrator.capturing_logger.captured_output.string
  rescue StandardError
    @orchestrator&.force_shutdown
    raise
  end

  after(:all) do
    AwsRubyDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin.clean_up_providers
    @orchestrator&.capturing_logger&.clear_captured_output
  end

  # =========================================================================
  # Helper methods
  # =========================================================================

  def switchover_post_offset_ms
    @orchestrator.switchover_post_offset_ms
  end

  def time_offset_ms(nano_time)
    @orchestrator.time_offset_ms(nano_time)
  end

  def bg_trigger_time
    @orchestrator.bg_trigger_time
  end

  def aurora_deployment?
    @env.deployment == Integration::DatabaseEngineDeployment::AURORA
  end

  # =========================================================================
  # Switchover lifecycle: phases, timing, no exceptions
  # =========================================================================

  context 'switchover lifecycle' do
    it 'completes without unhandled exceptions' do
      expect(@global.unhandled_exceptions).to be_empty,
                                              "Unhandled exceptions: #{@global.unhandled_exceptions.map do |e|
                                                "#{e.class}: #{e.message}"
                                              end.join('; ')}"
    end

    it 'does not exceed the orchestrator hard timeout' do
      expect(@global.timed_out?).to be(false),
                                    'Orchestrator hit the 12-minute hard timeout ceiling — switchover may have hung. ' \
                                    'Check logs for last observed phase.'
    end

    it 'switchover completes or rolls back to a valid end state' do
      if @global.rollback?
        expect(@global.rollback_final_phase.get).to eq('CREATED'),
                                                    "Rollback detected but final phase was '#{@global.rollback_final_phase.get}' " \
                                                    'instead of CREATED. Deployment may be stuck.'
      else
        green_completed = @orchestrator.instance_results.values.any? do |r|
          r.green_status_times.key?('SWITCHOVER_COMPLETED')
        end
        # On RDS instances, the DirectTopology thread may get killed during switchover before
        # observing SWITCHOVER_COMPLETED. Fall back to the plugin's authoritative COMPLETED signal.
        plugin_completed = @global.switchover_done?
        expect(green_completed ||
               plugin_completed).to be(true),
                                    'Expected SWITCHOVER_COMPLETED in green status times or plugin completion but not ' \
                                    "found. Observed green phases: #{@orchestrator.instance_results.values.flat_map do |r|
                                      r.green_status_times.keys
                                    end.uniq.join(', ')}"
      end
    end

    it 'emits the BG readiness log before switchover trigger' do
      expect(@global.green_topology_recognized_logged.true?).to be(true),
                                                                'Expected "Blue/Green target topology recognized" log with ready: true ' \
                                                                'to be emitted before switchover, but it was not found in captured logs'

      recognized_time = @global.green_topology_recognized_time.get
      trigger_time = @global.bg_trigger_time.get
      expect(recognized_time).to be < trigger_time,
                                 'BG readiness log was emitted AFTER the switchover was triggered ' \
                                 "(readiness offset: #{time_offset_ms(recognized_time)}ms, trigger: 0ms). " \
                                 'The plugin should recognize green topology before the switchover begins.'
    end

    it 'switchover hold duration is within acceptable bounds (< 180s)' do
      skip 'Switchover rolled back' if @global.rollback?

      # Parse all "held for X ms" messages from the captured log. The BG plugin emits these
      # when suspended connect/execute calls are released after switchover completes.
      held_durations_ms = @captured_log.scan(/The call was held for (\d+) ms/).flatten.map(&:to_i)

      expect(held_durations_ms).not_to be_empty,
                                       'Expected at least one "held for" log message indicating the BG plugin ' \
                                       'suspended and released calls during switchover, but found none.'

      max_hold_ms = held_durations_ms.max
      expect(max_hold_ms).to be < 180_000,
                             "BG plugin held a call for #{max_hold_ms}ms which exceeds the configured " \
                             'bg_switchover_timeout_ms of 180,000ms. Longest holds (ms): ' \
                             "#{held_durations_ms.sort.last(5).reverse.join(', ')}"
    end

    it 'outputs switchover summary log with phases in chronological order' do
      summary = parse_switchover_summary(@captured_log)
      expect(summary).not_to be_nil, 'Switchover summary was not found in captured logs'

      events = summary.map { |row| row[:event].strip }

      # Must contain key phases present in all paths
      expect(events).to include('NOT_CREATED')
      expect(events).to include('CREATED')

      if @global.rollback?
        # Rollback path: NOT_CREATED → CREATED → PREPARATION → CREATED (rollback)
        # IN_PROGRESS may not be reached if rollback happens during PREPARATION
        expect(@captured_log).to include('ROLLED BACK')
        expect(events).to include('PREPARATION')
        rollback_event = events.any? { |e| e.include?('rollback') }
        expect(rollback_event).to be(true),
                                  "Expected a '(rollback)' phase in summary events but found: #{events.inspect}"
      else
        # Successful path: must include IN_PROGRESS and COMPLETED
        expect(events).to include('IN_PROGRESS')
        expect(events).to include('COMPLETED')
      end

      # Offsets are monotonically non-decreasing (chronological)
      offsets = summary.map { |row| row[:offset_ms] }
      expect(offsets).to eq(offsets.sort),
                         "Phase offsets are not chronological: #{offsets.inspect}"

      # Zero-reference: IN_PROGRESS for success, PREPARATION for rollback
      if @global.rollback?
        prep_row = summary.find { |r| r[:event].strip == 'PREPARATION' }
        expect(prep_row).not_to be_nil, 'PREPARATION phase not found in rollback summary'
        expect(prep_row[:offset_ms]).to eq(0),
                                        "PREPARATION should be the zero-reference for rollback but has offset #{prep_row[:offset_ms]}ms"
      else
        in_progress_row = summary.find { |r| r[:event].strip == 'IN_PROGRESS' }
        expect(in_progress_row).not_to be_nil, 'IN_PROGRESS phase not found in summary'
        expect(in_progress_row[:offset_ms]).to eq(0),
                                               "IN_PROGRESS should be the zero-reference but has offset #{in_progress_row[:offset_ms]}ms"
      end
    end
  end

  # =========================================================================
  # Connection routing: blue dies, wrapper survives, routes to green
  # =========================================================================

  context 'connection routing' do
    it 'detects blue DNS IP address change' do
      skip 'Switchover rolled back' if @global.rollback?

      expect(@orchestrator.all_blue_dns_changed?).to be(true),
                                                     'Expected all blue instance DNS IPs to change during switchover, but some did not. ' \
                                                     "Unchanged: #{@orchestrator.blue_instances.reject do |id|
                                                       @orchestrator.instance_results[id].dns_blue_changed_time.get.positive?
                                                     end.join(', ')}"
    end

    it 'detects green DNS removal' do
      skip 'Switchover rolled back' if @global.rollback?

      expect(@orchestrator.any_green_dns_removed?).to be(true),
                                                      'Expected at least one green instance DNS to be removed ' \
                                                      'during switchover, but none were.'
    end

    it 'direct (non-wrapper) blue connection loses connectivity during switchover' do
      skip 'Switchover rolled back' if @global.rollback?

      still_alive = @orchestrator.blue_instances.reject do |id|
        @orchestrator.instance_results[id].direct_blue_lost_connection_time.get.positive?
      end
      expect(@orchestrator.all_direct_blue_lost_connection?).to be(true),
                                                                'Expected all direct (non-BG-plugin) blue connections to lose ' \
                                                                'connectivity during switchover, but some remained connected. ' \
                                                                'This validates that without the BG plugin, connections die. ' \
                                                                "Still alive: #{still_alive.join(', ')}"
    end

    it 'wrapper connections succeed after switchover completes' do
      skip 'Switchover rolled back' if @global.rollback?

      successful = @orchestrator.successful_wrapper_connections_after(switchover_post_offset_ms)
      expect(successful).to be > 0,
                            'Expected at least one successful wrapper connection after switchover complete ' \
                            "(complete_time offset: #{switchover_post_offset_ms}ms), found #{successful}"
    end

    it 'wrapper executions succeed after switchover completes' do
      skip 'Switchover rolled back' if @global.rollback?

      successful = @orchestrator.successful_wrapper_executions_after_switchover
      expect(successful).to be > 0,
                            "Expected at least one successful wrapper execution after switchover, found #{successful}"
    end

    it 'wrapper connections route to green host after switchover completes' do
      skip 'Switchover rolled back' if @global.rollback?
      skip 'Cannot differentiate blue/green hosts on RDS Multi-AZ instances' unless aurora_deployment?

      results = @orchestrator.combo_results_for('bg')
      post_switchover_verifications = results.flat_map(&:host_verification_results).select do |r|
        r.success? && time_offset_ms(r.timestamp) > switchover_post_offset_ms
      end

      expect(post_switchover_verifications).not_to be_empty,
                                                   'No successful host verification results found after switchover — ' \
                                                   'the HostVerification thread may have stopped before POST phase.'

      routed_to_green = post_switchover_verifications.reject(&:connected_to_blue)
      expect(routed_to_green).not_to be_empty,
                                     'All post-switchover connections still landed on the original blue host. ' \
                                     'The BG plugin should redirect connections to green hosts after switchover. ' \
                                     "Sampled #{post_switchover_verifications.size} connections, " \
                                     'all matched original blue identity.'
    end
  end

  # =========================================================================
  # Failover plugin integration (Aurora only)
  # =========================================================================

  context 'bg,failover plugin combination' do
    before(:each) do
      skip 'bg,failover only tested on Aurora deployments' unless @env.deployment == Integration::DatabaseEngineDeployment::AURORA
    end

    it 'raises at least one FailoverSuccessError per host during switchover' do
      skip 'Switchover rolled back' if @global.rollback?

      results = @orchestrator.combo_results_for('bg,failover')
      expect(results).not_to be_empty,
                             'No combo results found for bg,failover — threads may not have been created'

      results.each do |r|
        expect(r.failover_success_errors.size).to be >= 1,
                                                  "Expected at least 1 FailoverSuccessError for 'bg,failover' on #{r.host_id}, " \
                                                  "got #{r.failover_success_errors.size}. " \
                                                  'The BG plugin should hold the query, release after switchover, ' \
                                                  'and the failover plugin should reconnect to the green host.'
      end
    end

    it 'queries succeed on new host after FailoverSuccessError' do
      skip 'Switchover rolled back' if @global.rollback?

      results = @orchestrator.combo_results_for('bg,failover')
      successes = results.flat_map(&:failover_post_reconnect_successes)
      expect(successes).not_to be_empty,
                               'Expected successful queries after FailoverSuccessError but found none'
    end

    it 'does not raise FailoverFailedError' do
      results = @orchestrator.combo_results_for('bg,failover')
      failures = results.flat_map(&:failover_failed_errors)
      expect(failures).to be_empty,
                          "FailoverFailedError raised #{failures.size} times. " \
                          'Failover should always succeed during BG switchover. ' \
                          "Errors: #{failures.map { |e| e[:message] }.join('; ')}"
    end

    it 'does not raise BlueGreenTimeoutError' do
      results = @orchestrator.combo_results_for('bg,failover')
      timeouts = results.flat_map(&:bg_timeout_errors)
      expect(timeouts).to be_empty,
                          "BlueGreenTimeoutError raised #{timeouts.size} times. " \
                          'The BG hold should release before the timeout. ' \
                          "Errors: #{timeouts.map { |e| e[:message] }.join('; ')}"
    end
  end

  # =========================================================================
  # IAM plugin integration
  # =========================================================================

  context 'bg,iam plugin combo' do
    before(:each) do
      skip 'IAM not enabled in this environment' unless @iam_enabled
    end

    it 'wrapper executions succeed after switchover' do
      skip 'Switchover rolled back' if @global.rollback?

      results = @orchestrator.combo_results_for('bg,iam')
      expect(results).not_to be_empty,
                             'No combo results found for bg,iam — threads may not have been created'

      successes = results.sum do |r|
        r.wrapper_post_switchover_execute_times.count { |t| t.error.nil? }
      end
      expect(successes).to be > 0,
                           "Expected successful wrapper executions for 'bg,iam' after switchover, found #{successes}. " \
                           'The IAM plugin should generate valid tokens for the green host after BG routing completes.'
    end

    it 'new connections succeed after switchover' do
      skip 'Switchover rolled back' if @global.rollback?

      results = @orchestrator.combo_results_for('bg,iam')
      successes = results.sum do |r|
        r.wrapper_connect_times.count { |t| t.error.nil? }
      end
      expect(successes).to be > 0,
                           "Expected successful IAM wrapper connections for 'bg,iam' after switchover, found #{successes}. " \
                           'The BG plugin should route new connections to the green host and IAM should authenticate.'
    end
  end

  context 'bg,failover,iam plugin combo' do
    before(:each) do
      skip 'IAM not enabled in this environment' unless @iam_enabled
      skip 'bg,failover,iam only tested on Aurora deployments' unless aurora_deployment?
    end

    it 'raises at least one FailoverSuccessError' do
      skip 'Switchover rolled back' if @global.rollback?

      results = @orchestrator.combo_results_for('bg,failover,iam')
      expect(results).not_to be_empty,
                             'No combo results found for bg,failover,iam — threads may not have been created'

      errors = results.flat_map(&:failover_success_errors)
      expect(errors.size).to be >= 1,
                             "Expected at least 1 FailoverSuccessError for 'bg,failover,iam', got #{errors.size}. " \
                             'The IAM+failover combo should behave identically to bg,failover for failover triggering.'
    end

    it 'queries succeed after failover reconnect' do
      skip 'Switchover rolled back' if @global.rollback?

      results = @orchestrator.combo_results_for('bg,failover,iam')
      successes = results.flat_map(&:failover_post_reconnect_successes)
      expect(successes).not_to be_empty,
                               "Expected successful queries after FailoverSuccessError for 'bg,failover,iam' but found none"
    end

    it 'does not raise FailoverFailedError' do
      results = @orchestrator.combo_results_for('bg,failover,iam')
      failures = results.flat_map(&:failover_failed_errors)
      expect(failures).to be_empty,
                          "FailoverFailedError raised #{failures.size} times for 'bg,failover,iam'. " \
                          "Errors: #{failures.map { |e| e[:message] }.join('; ')}"
    end
  end

  private

  # Parses the switchover summary block from captured log output.
  # Returns an array of {timestamp:, offset_ms:, event:} hashes, or nil if not found.
  def parse_switchover_summary(log_string)
    # Match the summary block
    match = log_string.match(
      %r{Blue/Green Deployment Switchover (COMPLETED|ROLLED BACK)\n-+\n.+\n-+\n(.+?)\n-+}m
    )
    return nil unless match

    rows_text = match[2]
    rows = []
    rows_text.each_line do |line|
      # Pattern: <timestamp>  <offset> ms  <event>
      next unless (m = line.match(/^\s*(.+?)\s+(-?\d+)\s+ms\s+(.+?)\s*$/))

      rows << {
        timestamp: m[1].strip,
        offset_ms: m[2].to_i,
        event: m[3].strip
      }
    end

    rows.empty? ? nil : rows
  end
end
