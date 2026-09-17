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

require_relative '../errors'
require_relative '../property_definition'
require_relative 'rds_utils'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module AccessibleRegions
      module_function

      def parse(props)
        value = PropertyDefinition::ACCESSIBLE_REGIONS.get(props)
        return nil if value.nil? || value.strip.empty?

        regions = value.split(',').map { |r| r.strip.downcase }.reject(&:empty?)

        invalid = regions.reject { |r| RdsUtils.valid_region?(r) }
        unless invalid.empty?
          raise Errors::AwsError,
                "#{PropertyDefinition::ACCESSIBLE_REGIONS.name} contains unknown or misspelled AWS " \
                "region(s): #{invalid.join(', ')}"
        end

        regions.empty? ? nil : regions.to_set
      end

      def filter_by_region(hosts, accessible_regions)
        return hosts if accessible_regions.nil?

        hosts.select do |host|
          region = RdsUtils.rds_region(host.host)
          region && accessible_regions.include?(region.downcase)
        end
      end
    end
  end
end
