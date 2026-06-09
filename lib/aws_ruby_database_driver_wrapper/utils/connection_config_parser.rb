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

        initial_args = args.dup
        initial_options = kwargs.dup

        config = if args.length == 1 && args.first.is_a?(String)
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

        config.initial_args = initial_args
        config.initial_options = initial_options
        config.instance_variable_set(:@multi_host, config.initial_host_info&.host&.include?(',') || false)
        config
      end

      # Parses a URI connection string, e.g.
      #   "postgresql://user:pass@host1,host2:5432/mydb?sslmode=require"
      def parse_uri(driver_name, uri_string, **overrides)
        # eg ["postgresql", "user:pass@host1,host2:5432/mydb?sslmode=require"]
        scheme_rest = uri_string.split('://', 2)
        # eg "user:pass@host1,host2:5432/mydb?sslmode=require"
        authority_and_rest = scheme_rest[1] || ''
        # eg "host1,host2:5432"
        host_section = extract_host_section(authority_and_rest)

        # eg "user", "pass", "/mydb", "sslmode=require"
        user, password, path, query_string = parse_uri_parts(uri_string, authority_and_rest)
        # eg {"sslmode" => "require"}
        query_params = query_string ? URI.decode_www_form(query_string).to_h : {}
        # eg {host: "host1,host2", user: "user", password: "pass", dbname: "mydb", sslmode: "require"}
        driver_config = uri_to_config(user, password, path, driver_name)
        # eg {sslmode: "require"}
        all_props = query_params.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        overrides.transform_keys(&:to_sym).each { |k, v| all_props[k] = v }

        # eg {}, {sslmode: "require"}, {}
        wrapper_config, extra_driver, prefixed_config = split_props(all_props)
        driver_config.merge!(extra_driver)

        # Host and port are captured in initial_host_info for URIs, not in driver_props.
        driver_config.delete(:host)
        driver_config.delete(:port)

        initial_host_info = string_to_host_info(host_section)

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
        driver_config[:port] = driver_config[:port].to_s if driver_config.key?(:port)
        initial_host_info = hash_to_host_info(driver_config)

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
        driver_config[:port] = driver_config[:port].to_s if driver_config.key?(:port)
        initial_host_info = hash_to_host_info(driver_config)

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

      # Forms a HostInfo object from a URI host section string.
      # Each host entry may or may not have a port; missing ports are represented as -1.
      # The resulting port is a comma-delimited string of per-host ports.
      def string_to_host_info(host, _default_port = nil)
        host_str = host&.strip
        return nil if host_str.nil? || host_str.empty?

        entries = host_str.split(',').map(&:strip)
        hosts = []
        ports = []
        entries.each do |entry|
          if entry.include?(':')
            h, p = entry.split(':', 2)
            hosts << h
            ports << p.to_s
          else
            hosts << entry
            ports << Host::HostInfo::NO_PORT
          end
        end

        port_str = ports.uniq.length == 1 ? ports.first : ports.join(',')
        Host::HostInfo.new(host: hosts.join(','), port: port_str)
      end

      # Forms a HostInfo object from hash-style input.
      # If a single port is given (even with multiple hosts), the port is kept as-is.
      # The resulting port is always a string.
      def hash_to_host_info(hash)
        host_str = hash[:host]&.strip || hash[:hostname]&.strip
        return nil unless host_str

        port_str = hash[:port]&.to_s&.strip
        port_str.to_s.empty? ? Host::HostInfo.new(host: host_str) : Host::HostInfo.new(host: host_str, port: port_str)
      end

      def extract_host_section(authority_and_rest)
        without_userinfo = if authority_and_rest.include?('@')
                             authority_and_rest.split('@', 2).last
                           else
                             authority_and_rest
                           end
        without_userinfo.split(%r{[/?#]}, 2).first || ''
      end

      # Parses user, password, path, and query from a PostgreSQL-style URI.
      # Falls back to manual parsing when URI.parse fails (e.g. multi-host with per-host ports).
      def parse_uri_parts(uri_string, authority_and_rest)
        begin
          parsed = URI.parse(uri_string)
          user = parsed.user ? URI.decode_www_form_component(parsed.user) : nil
          password = parsed.password ? URI.decode_www_form_component(parsed.password) : nil
          path = parsed.path
          query_string = parsed.query
        rescue URI::InvalidURIError
          # Manual parsing for multi-host URIs that break standard URI parsing
          user, password = extract_userinfo(authority_and_rest)
          path, query_string = extract_path_and_query(authority_and_rest)
        end
        [user, password, path, query_string]
      end

      # Extracts user:password from the authority section before the @ sign.
      def extract_userinfo(authority_and_rest)
        return [nil, nil] unless authority_and_rest.include?('@')

        userinfo = authority_and_rest.split('@', 2).first
        if userinfo.include?(':')
          user, pass = userinfo.split(':', 2)
          [URI.decode_www_form_component(user), URI.decode_www_form_component(pass)]
        else
          [URI.decode_www_form_component(userinfo), nil]
        end
      end

      # Extracts path and query string from the authority-and-rest section.
      def extract_path_and_query(authority_and_rest)
        without_userinfo = if authority_and_rest.include?('@')
                             authority_and_rest.split('@', 2).last
                           else
                             authority_and_rest
                           end
        # Remove host section
        remainder = without_userinfo.split(%r{[/?#]}, 2)[1] || ''

        # Determine if we split on / or ?
        first_delim_idx = without_userinfo.index(%r{[/?#]})
        if first_delim_idx.nil?
          ['', nil]
        else
          delim = without_userinfo[first_delim_idx]
          if delim == '/'
            path_and_query = "/#{remainder}"
            if path_and_query.include?('?')
              path, query = path_and_query.split('?', 2)
              [path, query]
            else
              [path_and_query, nil]
            end
          elsif delim == '?'
            ['', remainder]
          else
            ['', nil]
          end
        end
      end

      def uri_to_config(user, password, path, protocol)
        config = {}
        config[:user] = user if user
        config[:password] = password if password

        db = path&.sub(%r{^/}, '')
        unless db.to_s.empty?
          config[protocol == :postgresql ? :dbname : :database] = db
        end

        config
      end
    end
  end
end
