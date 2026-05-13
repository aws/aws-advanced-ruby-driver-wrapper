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

require_relative 'rds_url_type'

module AwsRubyDatabaseDriverWrapper
  module Utils
    # Utility module for parsing and classifying Amazon RDS/Aurora endpoint hostnames.
    #
    # Determines endpoint type (writer cluster, reader cluster, instance, proxy, etc.),
    # extracts metadata (region, cluster ID, instance ID), and supports blue/green
    # deployment host manipulation.
    #
    # Aurora endpoint format reference:
    #   https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html
    #
    # Cluster (Writer):  <db-cluster>.cluster-<xyz>.<region>.rds.amazonaws.com
    # Cluster Reader:    <db-cluster>.cluster-ro-<xyz>.<region>.rds.amazonaws.com
    # Custom Cluster:    <alias>.cluster-custom-<xyz>.<region>.rds.amazonaws.com
    # Instance:          <instance>.<xyz>.<region>.rds.amazonaws.com
    # RDS Proxy:         <proxy>.proxy-<xyz>.<region>.rds.amazonaws.com
    # RDS Proxy Custom:  <name>.endpoint.proxy-<xyz>.<region>.rds.amazonaws.com
    # Global DB Writer:  <gdb>.global-<xyz>.global.rds.amazonaws.com
    # Limitless:         <db>.shardgrp-<xyz>.<region>.rds.amazonaws.com
    #
    # China regions use a different structure:
    #   New:  <xyz>.rds.<region>.amazonaws.com.cn
    #   Old:  <xyz>.<region>.rds.amazonaws.com.cn
    #
    # Gov/ISO/ISOB regions:
    #   <xyz>.(rds|rds-fips).<region>.(amazonaws.com|c2s.ic.gov|sc2s.sgov.gov)
    module RdsUtils
      extend self

      # -- Standard commercial regions --
      AURORA_DNS_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>proxy-|cluster-|cluster-ro-|cluster-custom-|shardgrp-)?
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.(?:rds|rds-fips)\.amazonaws\.(?:com|au|eu|uk)\.?)$
      /ix.freeze

      AURORA_CLUSTER_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>cluster-|cluster-ro-)+
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.(?:rds|rds-fips)\.amazonaws\.(?:com|au|eu|uk)\.?)$
      /ix.freeze

      # -- Limitless (covers all TLD variants) --
      AURORA_LIMITLESS_CLUSTER_PATTERN = /
        (?<instance>.+)\.
        (?<dns>shardgrp-)+
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.(?:rds|rds-fips)\.(?:amazonaws\.com\.?|amazonaws\.eu\.?|amazonaws\.au\.?|amazonaws\.uk\.?
        |amazonaws\.com\.cn\.?|sc2s\.sgov\.gov\.?|c2s\.ic\.gov\.?))$
      /ix.freeze

      # -- China (new format: <xyz>.rds.<region>.amazonaws.com.cn) --
      AURORA_CHINA_DNS_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>proxy-|cluster-|cluster-ro-|cluster-custom-|shardgrp-)?
        (?<domain>[a-zA-Z0-9]+\.(?:rds|rds-fips)\.(?<region>[a-zA-Z0-9-]+)
        \.amazonaws\.com\.cn\.?)$
      /ix.freeze

      AURORA_CHINA_CLUSTER_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>cluster-|cluster-ro-)+
        (?<domain>[a-zA-Z0-9]+\.(?:rds|rds-fips)\.(?<region>[a-zA-Z0-9-]+)
        \.amazonaws\.com\.cn\.?)$
      /ix.freeze

      # -- China (old/legacy format: <xyz>.<region>.rds.amazonaws.com.cn) --
      AURORA_OLD_CHINA_DNS_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>proxy-|cluster-|cluster-ro-|cluster-custom-|shardgrp-)?
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.(?:rds|rds-fips)\.amazonaws\.com\.cn\.?)$
      /ix.freeze

      AURORA_OLD_CHINA_CLUSTER_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>cluster-|cluster-ro-)+
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.(?:rds|rds-fips)\.amazonaws\.com\.cn\.?)$
      /ix.freeze

      # -- Gov / ISO / ISOB regions --
      AURORA_GOV_DNS_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>proxy-|cluster-|cluster-ro-|cluster-custom-|shardgrp-)?
        (?<domain>[a-zA-Z0-9]+\.(?:rds|rds-fips)\.(?<region>[a-zA-Z0-9-]+)
        \.(?:amazonaws\.com\.?|c2s\.ic\.gov\.?|sc2s\.sgov\.gov\.?))$
      /ix.freeze

      AURORA_GOV_CLUSTER_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>cluster-|cluster-ro-)+
        (?<domain>[a-zA-Z0-9]+\.(?:rds|rds-fips)\.(?<region>[a-zA-Z0-9-]+)
        \.(?:amazonaws\.com\.?|c2s\.ic\.gov\.?|sc2s\.sgov\.gov\.?))$
      /ix.freeze

      # -- ELB (region extraction only) --
      ELB_PATTERN = /
        ^(?<instance>.+)\.elb\.
        (?<region>[a-zA-Z0-9-]+)\.amazonaws\.(?:com|au|eu|uk)\.?$
      /ix.freeze

      # -- IP addresses --
      IP_V4 = /
        ^(?:[1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.
        (?:(?:[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){2}
        (?:[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$
      /x.freeze

      IP_V6 = /^[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}$/i.freeze

      IP_V6_COMPRESSED = /
        ^(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,5})?
        ::
        (?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,5})?$
      /ix.freeze

      # -- Blue/green deployment --
      BG_GREEN_HOST_PATTERN = /.*(?<prefix>-green-[0-9a-z]{6})\..*/i.freeze
      BG_GREEN_HOSTID_PATTERN = /(.*)-green-[0-9a-z]{6}$/i.freeze
      BG_OLD_HOST_PATTERN = /.*(?<prefix>-old1)\..*/i.freeze

      # -- Global database --
      AURORA_GLOBAL_WRITER_DNS_PATTERN = /
        ^(?<instance>.+)\.
        (?<dns>global-)?
        (?<domain>[a-zA-Z0-9]+\.global\.rds\.amazonaws\.com\.?)$
      /ix.freeze

      # -- RDS Proxy endpoints --
      RDS_PROXY_ENDPOINT_DNS_PATTERN = /
        ^(?<instance>.+)\.endpoint\.
        (?<dns>proxy-)?
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.rds\.amazonaws\.com\.?)$
      /ix.freeze

      RDS_PROXY_ENDPOINT_CHINA_DNS_PATTERN = /
        ^(?<instance>.+)\.endpoint\.
        (?<dns>proxy-)+
        (?<domain>[a-zA-Z0-9]+\.rds\.(?<region>[a-zA-Z0-9-]+)
        \.amazonaws\.com\.cn\.?)$
      /ix.freeze

      RDS_PROXY_ENDPOINT_OLD_CHINA_DNS_PATTERN = /
        ^(?<instance>.+)\.endpoint\.
        (?<dns>proxy-)?
        (?<domain>[a-zA-Z0-9]+\.(?<region>[a-zA-Z0-9-]+)
        \.rds\.amazonaws\.com\.cn\.?)$
      /ix.freeze

      DNS_PATTERNS = [
        AURORA_DNS_PATTERN,
        AURORA_CHINA_DNS_PATTERN,
        AURORA_OLD_CHINA_DNS_PATTERN,
        AURORA_GOV_DNS_PATTERN
      ].freeze

      DNS_GROUP_PATTERNS = [
        AURORA_DNS_PATTERN,
        AURORA_CHINA_DNS_PATTERN,
        AURORA_OLD_CHINA_DNS_PATTERN,
        AURORA_GOV_DNS_PATTERN,
        AURORA_GLOBAL_WRITER_DNS_PATTERN
      ].freeze

      CLUSTER_PATTERNS = [
        [AURORA_CLUSTER_PATTERN, 'cluster-'],
        [AURORA_CHINA_CLUSTER_PATTERN, 'cluster-'],
        [AURORA_OLD_CHINA_CLUSTER_PATTERN, 'cluster-'],
        [AURORA_GOV_CLUSTER_PATTERN, 'cluster-'],
        [AURORA_LIMITLESS_CLUSTER_PATTERN, 'shardgrp-']
      ].freeze

      PROXY_ENDPOINT_PATTERNS = [
        RDS_PROXY_ENDPOINT_DNS_PATTERN,
        RDS_PROXY_ENDPOINT_CHINA_DNS_PATTERN,
        RDS_PROXY_ENDPOINT_OLD_CHINA_DNS_PATTERN
      ].freeze

      @cached_matches = {}
      @cached_dns_groups = {}
      @mutex = Mutex.new
      @prepare_host_func = nil

      def clear_cache
        @mutex.synchronize do
          @cached_matches.clear
          @cached_dns_groups.clear
        end
      end

      attr_accessor :prepare_host_func

      def reset_prepare_host_func
        @prepare_host_func = nil
      end

      def rds_dns?(host)
        prepared = prepared_host(host)
        groups = cache_match(prepared, *DNS_PATTERNS)
        if groups
          dns = groups['dns']
          @mutex.synchronize { @cached_dns_groups[prepared] = dns } if dns
          true
        else
          false
        end
      end

      def rds_cluster_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && (dns.casecmp('cluster-').zero? || dns.casecmp('cluster-ro-').zero?)
      end

      def rds_custom_cluster_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && dns.downcase.start_with?('cluster-custom-')
      end

      def rds_instance?(host)
        prepared = prepared_host(host)
        dns_group(prepared).nil? && rds_dns?(prepared)
      end

      def rds_proxy_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && dns.downcase.start_with?('proxy-')
      end

      def rds_proxy_endpoint_dns?(host)
        prepared = prepared_host(host)
        return false if blank?(prepared)

        groups = match_first(prepared, *PROXY_ENDPOINT_PATTERNS)
        !groups.nil? && !groups['dns'].nil? && !groups['instance'].nil?
      end

      def writer_cluster_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && dns.casecmp('cluster-').zero?
      end

      def reader_cluster_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && dns.casecmp('cluster-ro-').zero?
      end

      def limitless_db_shard_group_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && dns.casecmp('shardgrp-').zero?
      end

      def global_db_writer_cluster_dns?(host)
        dns = dns_group(prepared_host(host))
        !dns.nil? && dns.casecmp('global-').zero?
      end

      def ip?(host)
        ipv4?(host) || ipv6?(host)
      end

      def ipv4?(host)
        !blank?(host) && IP_V4.match?(host)
      end

      def ipv6?(host)
        !blank?(host) && (IP_V6.match?(host) || IP_V6_COMPRESSED.match?(host))
      end

      # Priority-ordered type checks; first match wins.
      RDS_TYPE_CHECKS = [
        [:ip?,                            RdsUrlType::IP_ADDRESS],
        [:global_db_writer_cluster_dns?,  RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER],
        [:writer_cluster_dns?,            RdsUrlType::RDS_WRITER_CLUSTER],
        [:reader_cluster_dns?,            RdsUrlType::RDS_READER_CLUSTER],
        [:rds_custom_cluster_dns?,        RdsUrlType::RDS_CUSTOM_CLUSTER],
        [:limitless_db_shard_group_dns?,  RdsUrlType::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP],
        [:rds_proxy_endpoint_dns?,        RdsUrlType::RDS_PROXY_ENDPOINT],
        [:rds_proxy_dns?,                 RdsUrlType::RDS_PROXY],
        [:rds_dns?,                       RdsUrlType::RDS_INSTANCE]
      ].freeze

      def identify_rds_type(host)
        return RdsUrlType::OTHER if blank?(host)

        RDS_TYPE_CHECKS.each do |check, type|
          return type if send(check, host)
        end

        RdsUrlType::OTHER
      end

      def rds_host_id(host)
        prepared = prepared_host(host)
        return nil if blank?(prepared)

        groups = cache_match(prepared, *DNS_PATTERNS)
        return nil unless groups

        groups['dns'] ? groups['instance'] : nil
      end

      def rds_instance_id(host)
        prepared = prepared_host(host)
        return nil if blank?(prepared)

        groups = cache_match(prepared, *DNS_PATTERNS)
        return nil unless groups

        groups['dns'].nil? ? groups['instance'] : nil
      end

      def rds_instance_host_pattern(host)
        prepared = prepared_host(host)
        return nil if blank?(prepared)

        groups = cache_match(prepared, *DNS_PATTERNS)
        domain = groups&.[]('domain')
        domain ? "?.#{domain}" : nil
      end

      def rds_region(host)
        prepared = prepared_host(host)
        return nil if blank?(prepared)

        groups = cache_match(prepared, *DNS_PATTERNS)
        region = groups&.[]('region')
        return region if region

        elb_match = ELB_PATTERN.match(prepared)
        elb_match&.[]('region')
      end

      def same_region?(host1, host2)
        return false if blank?(host1) || blank?(host2)

        region1 = rds_region(host1)
        region2 = rds_region(host2)
        !region1.nil? && region1.casecmp(region2).zero?
      end

      def rds_cluster_host_url(host)
        prepared = prepared_host(host)
        return nil if blank?(prepared)

        CLUSTER_PATTERNS.each do |pattern, prefix|
          m = pattern.match(prepared)
          next unless m

          return "#{m[:instance]}.#{prefix}#{m[:domain]}"
        end

        nil
      end

      def dns_pattern_valid?(pattern)
        pattern.include?('?')
      end

      def remove_port(host_and_port)
        return host_and_port if blank?(host_and_port)

        idx = host_and_port.index(':')
        idx ? host_and_port[0...idx] : host_and_port
      end

      def green_instance?(host)
        prepared = prepared_host(host)
        !blank?(prepared) && BG_GREEN_HOST_PATTERN.match?(prepared)
      end

      def old_instance?(host)
        prepared = prepared_host(host)
        !blank?(prepared) && BG_OLD_HOST_PATTERN.match?(prepared)
      end

      def not_old_instance?(host)
        prepared = prepared_host(host)
        blank?(prepared) || !BG_OLD_HOST_PATTERN.match?(prepared)
      end

      def not_green_and_old_prefix_instance?(host)
        prepared = prepared_host(host)
        !blank?(prepared) &&
          !BG_GREEN_HOST_PATTERN.match?(prepared) &&
          !BG_OLD_HOST_PATTERN.match?(prepared)
      end

      def remove_green_instance_prefix(host)
        return nil if host.nil?
        return host if host.empty?

        prepared = prepared_host(host)
        m = BG_GREEN_HOST_PATTERN.match(prepared)
        unless m
          hostid_m = BG_GREEN_HOSTID_PATTERN.match(prepared)
          return hostid_m ? hostid_m[1] : host
        end

        prefix = m[:prefix]
        return host if blank?(prefix)

        host.sub("#{prefix}.", '.')
      end

      private

      def blank?(str)
        str.nil? || str.empty?
      end

      def prepared_host(host)
        return host unless @prepare_host_func

        result = @prepare_host_func.call(host)
        result || host
      end

      def cache_match(host, *patterns)
        @mutex.synchronize { return @cached_matches[host] if @cached_matches.key?(host) }

        patterns.each do |pattern|
          m = pattern.match(host)
          next unless m

          groups = m.named_captures
          @mutex.synchronize { @cached_matches[host] = groups }
          return groups
        end

        nil
      end

      def dns_group(host)
        return nil if blank?(host)

        @mutex.synchronize { return @cached_dns_groups[host] if @cached_dns_groups.key?(host) }

        groups = cache_match(host, *DNS_GROUP_PATTERNS)
        dns = groups&.[]('dns')
        @mutex.synchronize { @cached_dns_groups[host] = dns }
        dns
      end

      def match_first(host, *patterns)
        patterns.each do |pattern|
          m = pattern.match(host)
          return m.named_captures if m
        end
        nil
      end
    end
  end
end
