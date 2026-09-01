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

require_relative 'member_list_type'
require_relative 'role'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module CustomEndpoint
      # Represents custom endpoint information for a given custom endpoint.
      class Info
        attr_reader :endpoint_identifier, :cluster_identifier, :url, :role, :member_list_type, :members

        # @param endpoint_identifier [String] The endpoint identifier for the custom endpoint. For example, if the
        #   custom endpoint URL is "my-custom-endpoint.cluster-custom-XYZ.us-east-1.rds.amazonaws.com", the endpoint
        #   identifier is "my-custom-endpoint".
        # @param cluster_identifier [String] The cluster identifier for the cluster that the custom endpoint belongs to.
        # @param url [String] The URL for the custom endpoint.
        # @param role [Symbol] The role of the custom endpoint.
        # @param members [Enumerable<String>] The instance IDs for the hosts in the custom endpoint.
        # @param member_list_type [Symbol] The list type for +members+.
        def initialize(endpoint_identifier:,
                       cluster_identifier:,
                       url:,
                       role:,
                       members:,
                       member_list_type:)
          @endpoint_identifier = endpoint_identifier
          @cluster_identifier = cluster_identifier
          @url = url
          @role = role
          @members = members.to_set.freeze
          @member_list_type = member_list_type
        end

        def self.from_db_cluster_endpoint(response)
          static = response.static_members&.any?
          members = static ? response.static_members : response.excluded_members
          member_list_type = static ? MemberListType::STATIC_LIST : MemberListType::EXCLUSION_LIST

          new(
            endpoint_identifier: response.db_cluster_endpoint_identifier,
            cluster_identifier: response.db_cluster_identifier,
            url: response.endpoint,
            role: Role.parse(response.custom_endpoint_type),
            members: members,
            member_list_type: member_list_type
          )
        end

        # Evaluates whether instances in the custom endpoint must match a particular role according to the custom
        # endpoint properties. Note that custom clusters with static member lists always route to all static members,
        # even if the member is a writer and the custom endpoint is of type READER, so there are never role
        # requirements for static list custom clusters.
        # @return [Symbol, nil] the required role of instances in the custom endpoint, or nil if there is no strict
        #   role requirement.
        def required_role
          :reader if @member_list_type == MemberListType::EXCLUSION_LIST && @role == Role::READER
        end

        # Gets the static members of the custom endpoint. If the custom endpoint member list type is an exclusion
        # list, returns nil.
        # @return [Set<String>, nil]
        def static_members
          @members if @member_list_type == MemberListType::STATIC_LIST
        end

        # Gets the excluded members of the custom endpoint. If the custom endpoint member list type is a static
        # list, returns nil.
        # @return [Set<String>, nil]
        def excluded_members
          @members if @member_list_type == MemberListType::EXCLUSION_LIST
        end

        def ==(other)
          other.is_a?(Info) &&
            endpoint_identifier == other.endpoint_identifier &&
            cluster_identifier == other.cluster_identifier &&
            url == other.url &&
            role == other.role &&
            member_list_type == other.member_list_type &&
            members == other.members
        end

        alias eql? ==

        def hash
          [@endpoint_identifier, @cluster_identifier, @url, @role, @member_list_type, @members].hash
        end

        def to_s
          "Info[url=#{@url}, cluster=#{@cluster_identifier}, role=#{@role}, " \
            "member_list_type=#{@member_list_type}, members=#{@members}]"
        end
      end
    end
  end
end
