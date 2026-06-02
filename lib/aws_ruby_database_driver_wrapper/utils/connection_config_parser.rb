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

require 'uri'
require_relative 'connection_config'
require_relative '../property_definition'
require_relative '../host/host_availability'
require_relative '../host/host_availability_strategy'
require_relative '../host/host_info'
require_relative '../host/host_role'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module ConnectionConfigParser
      CONNINFO_PATTERN = /(\w+)=(?:'([^']*)'|(\S+))/.freeze

      module_function

      # Main entry point. The driver_name is provided by the wrapper class
      # (e.g. :postgresql from WrapperPgConnection, :mysql2 from Mysql2WrapperClient).
      #
      # @param driver_name [Symbol] :postgresql or :mysql2
      def parse(driver_name, *args, **kwargs)
        if driver_name == :mysql2 && !args.empty? && !args.first.is_a?(Hash)
          raise ArgumentError,
                "Mysql2WrapperClient only accepts keyword arguments (e.g. host: 'x', port: 3306). " \
                'URI strings and positional arguments are not supported.'
        end

        if args.length == 1 && args.first.is_a?(String)
          str = args.first
          if str.include?('://')
            parse_uri(driver_name, str, **kwargs)
          else
            parse_conninfo(driver_name, str, **kwargs)
          end
        elsif args.length == 1 && args.first.is_a?(Hash)
          parse_hash(driver_name, args.first.merge(kwargs))
        elsif args.empty? && !kwargs.empty?
          parse_hash(driver_name, kwargs)
        else
          parse_positional(driver_name, args, kwargs)
        end
      end

      # Parses a URI connection string, e.g.
      #   "postgresql://user:pass@host1,host2:5432/mydb?sslmode=require"
      def parse_uri(driver_name, uri_string, **overrides)
        scheme_rest = uri_string.split('://', 2)
        authority_and_rest = scheme_rest[1] || ''

        host_section = extract_host_section(authority_and_rest)

        # Pass URI with only first host so URI.parse can extract user/password/path/query.
        parsed_uri = URI.parse(uri_string.sub(host_section, host_section.split(',').first.to_s))
        user = parsed_uri.user ? URI.decode_www_form_component(parsed_uri.user) : nil
        password = parsed_uri.password ? URI.decode_www_form_component(parsed_uri.password) : nil

        query_params = parsed_uri.query ? URI.decode_www_form(parsed_uri.query).to_h : {}
        driver_config = build_driver_config_from_uri(host_section, user, password, parsed_uri, driver_name)
        all_props = query_params.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        overrides.transform_keys(&:to_sym).each { |k, v| all_props[k] = v }

        wrapper_config, extra_driver, prefixed_config = split_props(all_props)
        driver_config.merge!(extra_driver)

        initial_host_info = first_host_from_string(host_section, parsed_uri.port)

        ConnectionConfig.new(
          wrapper_props: wrapper_config,
          driver_props: driver_config,
          prefixed_props: prefixed_config,
          initial_host_info: initial_host_info,
          driver_name: driver_name
        )
      end

      # Parses libpq key=value conninfo strings, e.g. "host=localhost port=5432 dbname=mydb"
      def parse_conninfo(driver_name, conninfo, **overrides)
        params = conninfo.scan(CONNINFO_PATTERN).each_with_object({}) do |(k, v1, v2), h|
          h[k.to_sym] = v1 || v2
        end
        params.merge!(overrides)
        parse_hash(driver_name, params)
      end

      # Parses a flat keyword hash, e.g.
      #   parse_hash(:postgresql, { host: "myhost", port: 5432, dbname: "mydb", wrapper_plugins: "failover" })
      def parse_hash(driver_name, params)
        params = params.transform_keys(&:to_sym)
        wrapper_config, driver_config, prefixed_config = split_props(params)
        initial_host_info = first_host_from_hash(driver_config[:host] || driver_config[:hostname], driver_config[:port])

        ConnectionConfig.new(
          wrapper_props: wrapper_config,
          driver_props: driver_config,
          prefixed_props: prefixed_config,
          initial_host_info: initial_host_info,
          driver_name: driver_name
        )
      end

      # Parses PG-style positional arguments, e.g.
      #   parse_positional(:postgresql, ["myhost", 5432, nil, nil, "mydb", "user", "pass"], { cluster_id: "test" })
      def parse_positional(driver_name, args, kwargs)
        keys = %i[host port options tty dbname user password]
        positional = keys.zip(args).compact.to_h
        all_props = positional.merge(kwargs.transform_keys(&:to_sym))

        wrapper_config, driver_config, prefixed_config = split_props(all_props)
        initial_host_info = first_host_from_hash(driver_config[:host], driver_config[:port])

        ConnectionConfig.new(
          wrapper_props: wrapper_config,
          driver_props: driver_config,
          prefixed_props: prefixed_config,
          initial_host_info: initial_host_info,
          driver_name: driver_name
        )
      end

      # Splits a flat hash into wrapper_config, driver_config, and prefixed_config.
      # Keys matching a known prefix are stripped and grouped by prefix in prefixed_config.
      # Known wrapper properties go to wrapper_config. Everything else goes to driver_config.
      def split_props(props)
        wrapper_config = {}
        driver_config = {}
        prefixed_config = {}

        props.each do |key, value|
          key_s = key.to_s
          prefix = PropertyDefinition::KNOWN_PREFIXES.find { |p| key_s.start_with?(p) }
          if prefix
            (prefixed_config[prefix] ||= {})[key_s.delete_prefix(prefix).to_sym] = value
          elsif PropertyDefinition.wrapper_property?(key)
            wrapper_config[key.to_sym] = value
          else
            driver_config[key.to_sym] = value
          end
        end

        [wrapper_config, driver_config, prefixed_config]
      end

      # Extracts only the first host and its port as a HostInfo.
      def first_host_from_string(host_string, default_port)
        return nil if host_string.nil? || host_string.empty?

        first_entry = host_string.split(',', 2).first.strip
        host, port = first_entry.include?(':') ? first_entry.split(':', 2) : [first_entry, nil]
        resolved_port = (port || default_port)&.to_i || Host::HostInfo::NO_PORT
        Host::HostInfo.new(host: host.strip, port: resolved_port)
      end

      # Extracts only the first host and its port as a HostInfo from hash-style input.
      def first_host_from_hash(host_value, port)
        return nil unless host_value

        first_host = Array(host_value).flat_map { |h| h.to_s.split(',') }.first&.strip
        return nil unless first_host

        ports = port.to_s.split(',').map { |p| p.strip.to_i }
        resolved_port = ports.first || Host::HostInfo::NO_PORT
        resolved_port = Host::HostInfo::NO_PORT if resolved_port.zero?
        Host::HostInfo.new(host: first_host, port: resolved_port)
      end

      def extract_host_section(authority_and_rest)
        without_userinfo = if authority_and_rest.include?('@')
                             authority_and_rest.split('@', 2).last
                           else
                             authority_and_rest
                           end
        without_userinfo.split(%r{[/?#]}, 2).first || ''
      end

      def build_driver_config_from_uri(host_section, user, password, parsed_uri, protocol)
        config = {}

        entries = host_section.split(',').map(&:strip)
        hosts = []
        ports = []
        entries.each do |entry|
          if entry.include?(':')
            h, p = entry.split(':', 2)
            hosts << h
            ports << p.to_i
          else
            hosts << entry
            ports << parsed_uri.port if parsed_uri.port
          end
        end

        config[:host] = hosts.length > 1 ? hosts.join(',') : hosts.first
        if ports.length > 1
          config[:port] = ports.join(',')
        elsif ports.length == 1
          config[:port] = ports.first
        end

        config[:user] = user if user
        config[:password] = password if password

        db = parsed_uri.path&.sub(%r{^/}, '')
        unless db.to_s.empty?
          config[protocol == :postgresql ? :dbname : :database] = db
        end

        config
      end
    end
  end
end
