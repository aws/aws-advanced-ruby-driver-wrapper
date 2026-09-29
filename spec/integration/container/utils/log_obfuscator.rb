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

require 'logger'

module Integration
  # Masks the account-identifying portion of RDS endpoints in log output so CI logs do not leak the
  # cluster's DNS domain (the resource id and region that follow the endpoint-type prefix).
  module LogObfuscator
    # Matches an RDS hostname wherever it appears in a log line. '*' is intentionally excluded so an
    # already-masked host (e.g. one CI has partially redacted) is not re-matched.
    RDS_ENDPOINT = /[A-Za-z0-9._-]+\.rds\.amazonaws\.com/

    # Endpoint-type prefixes, longest first so a cluster-custom-/cluster-ro- endpoint keeps its marker
    # rather than collapsing to "cluster-***". ".global-" covers the Aurora GDB writer endpoint.
    CLUSTER_PREFIXES = ['.cluster-custom-', '.cluster-ro-', '.cluster-', '.global-'].freeze

    REDACTED = '***'

    module_function

    # Replaces every RDS endpoint in +text+ with its obfuscated form. Non-string input is returned as-is.
    #
    # @param text [String, nil]
    # @return [String, nil]
    def obfuscate(text)
      return text unless text.is_a?(String)

      text.gsub(RDS_ENDPOINT) { |host| obfuscate_host(host) }
    end

    # Masks a single RDS hostname, keeping only the leading label(s) that identify the endpoint's role:
    #   "name.cluster-abc123.us-east-2.rds.amazonaws.com"        -> "name.cluster-***"
    #   "name.cluster-ro-abc123.us-east-2.rds.amazonaws.com"     -> "name.cluster-ro-***"
    #   "name.cluster-custom-abc123.us-east-2.rds.amazonaws.com" -> "name.cluster-custom-***"
    #   "gdb-abc.global-xyz123.global.rds.amazonaws.com"         -> "gdb-abc.global-***"
    #   "instance-1.abc123.us-east-2.rds.amazonaws.com"          -> "instance-1.***"
    #
    # @param host [String]
    # @return [String]
    def obfuscate_host(host)
      CLUSTER_PREFIXES.each do |prefix|
        idx = host.index(prefix)
        return "#{host[0...idx]}#{prefix}#{REDACTED}" if idx
      end

      label, = host.split('.', 2)
      "#{label}.#{REDACTED}"
    end

    # Wraps +logger+ so its output has RDS endpoints obfuscated, composing with (not replacing) any
    # existing formatter. Idempotent: installing twice does not double-wrap.
    #
    # @param logger [Logger] a logger exposing #formatter and #formatter=
    # @return [Logger] the same logger, for chaining
    def install(logger)
      return logger if logger.nil? || logger.formatter.is_a?(ObfuscatingFormatter)

      logger.formatter = ObfuscatingFormatter.new(logger.formatter || Logger::Formatter.new)
      logger
    end

    # Delegates to a wrapped formatter and obfuscates the resulting line. A named class (rather than a
    # proc) lets {.install} detect and skip an already-wrapped logger.
    class ObfuscatingFormatter
      def initialize(base)
        @base = base
      end

      def call(severity, datetime, progname, msg)
        Integration::LogObfuscator.obfuscate(@base.call(severity, datetime, progname, msg))
      end
    end
  end
end
