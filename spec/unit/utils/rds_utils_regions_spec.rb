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

require_relative '../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_utils'

# RdsUtils::KNOWN_REGIONS is intentionally baked into the wrapper so that region
# validation works without the AWS SDK loaded and rejects typos deterministically.
# The trade-off is that a brand-new AWS region requires a wrapper update.
#
# This spec is the safety net for that trade-off: it compares the baked-in list
# against the authoritative aws-partitions region data (which is available in the
# test environment because we load the AWS SDK for other tests). If AWS adds a new
# region, this test fails and tells us exactly which region(s) to add or remove.
RSpec.describe 'RdsUtils::KNOWN_REGIONS drift against aws-partitions' do
  let(:baked_in) { AwsAdvancedRubyDriverWrapper::Utils::RdsUtils::KNOWN_REGIONS }

  # The '*-global' pseudo-regions reported by aws-partitions are not real RDS
  # deployment regions and are intentionally excluded from KNOWN_REGIONS.
  def sdk_regions
    require 'aws-partitions'
    Aws::Partitions.partitions
                   .flat_map { |partition| partition.regions.map(&:name) }
                   .reject { |name| name.end_with?('-global') }
                   .to_set
  rescue LoadError
    skip 'aws-partitions (from aws-sdk-core) is not available in this environment'
  end

  it 'matches the set of RDS-capable regions reported by the SDK' do
    sdk = sdk_regions

    missing_from_wrapper = sdk - baked_in
    stale_in_wrapper     = baked_in - sdk

    expect(missing_from_wrapper).to(
      be_empty,
      'aws-partitions knows regions not in RdsUtils::KNOWN_REGIONS: ' \
      "#{missing_from_wrapper.to_a.sort.join(', ')}. Add them to KNOWN_REGIONS."
    )
    expect(stale_in_wrapper).to(
      be_empty,
      'RdsUtils::KNOWN_REGIONS has regions unknown to aws-partitions: ' \
      "#{stale_in_wrapper.to_a.sort.join(', ')}. Remove them from KNOWN_REGIONS."
    )
  end
end
