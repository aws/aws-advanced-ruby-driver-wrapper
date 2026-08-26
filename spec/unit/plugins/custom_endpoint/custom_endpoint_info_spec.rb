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

require_relative '../../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/info'
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/member_list_type'
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/role'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::Info do
  let(:member_list_type) { AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::MemberListType }
  let(:role_class)       { AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::Role }

  def build_info(mlt: nil, role: nil, members: %w[m1 m2])
    mlt  ||= AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::MemberListType::STATIC_LIST
    role ||= AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::Role::ANY
    described_class.new(
      endpoint_identifier: 'my-custom',
      cluster_identifier: 'my-cluster',
      url: 'my-custom.cluster-custom-XYZ.us-east-1.rds.amazonaws.com',
      role: role,
      members: members,
      member_list_type: mlt
    )
  end

  describe '.from_db_cluster_endpoint' do
    it 'builds Info from a static member response' do
      response = double('response',
                        db_cluster_endpoint_identifier: 'ep1',
                        db_cluster_identifier: 'cluster1',
                        endpoint: 'ep1.cluster-custom-XYZ.us-east-1.rds.amazonaws.com',
                        custom_endpoint_type: 'ANY',
                        static_members: %w[m1 m2],
                        excluded_members: [])
      info = described_class.from_db_cluster_endpoint(response)
      expect(info.member_list_type).to eq(member_list_type::STATIC_LIST)
      expect(info.members).to eq(Set['m1', 'm2'])
      expect(info.role).to eq(role_class::ANY)
    end

    it 'builds Info from an exclusion list response' do
      response = double('response',
                        db_cluster_endpoint_identifier: 'ep1',
                        db_cluster_identifier: 'cluster1',
                        endpoint: 'ep1.cluster-custom-XYZ.us-east-1.rds.amazonaws.com',
                        custom_endpoint_type: 'READER',
                        static_members: nil,
                        excluded_members: ['m3'])
      info = described_class.from_db_cluster_endpoint(response)
      expect(info.member_list_type).to eq(member_list_type::EXCLUSION_LIST)
      expect(info.members).to eq(Set['m3'])
      expect(info.role).to eq(role_class::READER)
    end
  end

  describe '#static_members' do
    it 'returns members when list type is STATIC_LIST' do
      expect(build_info.static_members).to eq(Set['m1', 'm2'])
    end

    it 'returns nil when list type is EXCLUSION_LIST' do
      expect(build_info(mlt: member_list_type::EXCLUSION_LIST).static_members).to be_nil
    end
  end

  describe '#excluded_members' do
    it 'returns members when list type is EXCLUSION_LIST' do
      expect(build_info(mlt: member_list_type::EXCLUSION_LIST).excluded_members).to eq(Set['m1', 'm2'])
    end

    it 'returns nil when list type is STATIC_LIST' do
      expect(build_info.excluded_members).to be_nil
    end
  end

  describe '#required_role' do
    it 'returns :reader for EXCLUSION_LIST + READER role' do
      info = build_info(mlt: member_list_type::EXCLUSION_LIST, role: role_class::READER)
      expect(info.required_role).to eq(:reader)
    end

    it 'returns nil for STATIC_LIST (no role enforcement)' do
      expect(build_info(mlt: member_list_type::STATIC_LIST, role: role_class::READER).required_role).to be_nil
    end

    it 'returns nil for EXCLUSION_LIST + ANY role' do
      expect(build_info(mlt: member_list_type::EXCLUSION_LIST, role: role_class::ANY).required_role).to be_nil
    end
  end

  describe '#==' do
    it 'returns true for identical Info objects' do
      expect(build_info).to eq(build_info)
    end

    it 'returns false when members differ' do
      expect(build_info(members: ['m1'])).not_to eq(build_info(members: %w[m1 m2]))
    end

    it 'returns false when role differs' do
      expect(build_info(role: role_class::READER)).not_to eq(build_info(role: role_class::ANY))
    end

    it 'returns false when member_list_type differs' do
      expect(build_info(mlt: member_list_type::STATIC_LIST))
        .not_to eq(build_info(mlt: member_list_type::EXCLUSION_LIST))
    end
  end

  describe '#members' do
    it 'is frozen' do
      expect(build_info.members).to be_frozen
    end

    it 'deduplicates members' do
      info = build_info(members: %w[m1 m1 m2])
      expect(info.members.size).to eq(2)
    end
  end
end
