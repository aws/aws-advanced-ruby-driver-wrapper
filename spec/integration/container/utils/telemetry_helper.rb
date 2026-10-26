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

require_relative 'test_environment'
require_relative 'test_environment_features'

module Integration
  # Sends the wrapper's telemetry to the OpenTelemetry collector the test environment starts when the
  # telemetry features are enabled. The wrapper exports over OTLP; the collector then forwards traces
  # to AWS X-Ray and metrics to CloudWatch, where they help explain a failed run. Nothing here asserts
  # on what is sent.
  #
  # The wrapper only records telemetry through the OpenTelemetry API, so this installs the SDK the
  # way an application would.
  module TelemetryHelper
    SERVICE_NAME = 'aws-advanced-ruby-driver-wrapper-integration-tests'

    class << self
      def traces_enabled?
        TestEnvironment.current.features.include?(TestEnvironmentFeatures::TELEMETRY_TRACES_ENABLED)
      end

      def metrics_enabled?
        TestEnvironment.current.features.include?(TestEnvironmentFeatures::TELEMETRY_METRICS_ENABLED)
      end

      # @return [Hash] the wrapper properties that turn the enabled kinds of telemetry on
      def wrapper_props
        return {} unless traces_enabled? || metrics_enabled?

        pd = AwsAdvancedRubyDriverWrapper::PropertyDefinition
        {
          pd::ENABLE_TELEMETRY.name => true,
          pd::TELEMETRY_SUBMIT_TOP_LEVEL.name => true,
          pd::TELEMETRY_FAILOVER_ADDITIONAL_TOP_TRACE.name => true,
          pd::TELEMETRY_TRACES_BACKEND.name => traces_enabled? ? 'otlp' : 'none',
          pd::TELEMETRY_METRICS_BACKEND.name => metrics_enabled? ? 'otlp' : 'none'
        }
      end

      # Installs the OpenTelemetry SDK with exporters to the collector. Does nothing when neither kind
      # of telemetry is enabled, or when it has already been installed.
      def install
        return if @installed || !(traces_enabled? || metrics_enabled?)

        require 'opentelemetry/sdk'
        require 'opentelemetry-metrics-sdk' if metrics_enabled?
        # The exporters are added below, pointed at the collector. Without these, the SDK would also
        # add exporters of its own, pointed at localhost.
        ENV['OTEL_TRACES_EXPORTER'] = 'none'
        ENV['OTEL_METRICS_EXPORTER'] = 'none'
        # Export each counter's increments rather than its running total. The collector's CloudWatch
        # exporter turns running totals into increments itself, and drops the first value of each
        # counter in doing so, which loses that counter's first increment in every test run.
        ENV['OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE'] = 'delta'

        OpenTelemetry::SDK.configure do |config|
          config.service_name = SERVICE_NAME
          configure_traces(config) if traces_enabled?
        end
        configure_metrics if metrics_enabled?

        at_exit { shutdown }
        @installed = true
      end

      # Runs the example inside a span named after it, so that the traces the wrapper records during
      # the example can be found from it: each wrapper call is a trace of its own, which records the
      # ID of this one and links to it.
      def in_test_span(example, &)
        return yield unless @installed && traces_enabled?

        env = TestEnvironment.current
        attributes = {
          'test_name' => example.full_description,
          'engine' => env.engine.to_s,
          'deployment' => env.deployment.to_s,
          'ruby_version' => RUBY_VERSION
        }
        OpenTelemetry.tracer_provider.tracer(SERVICE_NAME).in_span("test: #{example.description}", attributes:, &)
      end

      private

      def configure_traces(config)
        require 'opentelemetry/exporter/otlp'
        require 'opentelemetry-propagator-xray'

        # X-Ray only accepts trace IDs that start with the time the trace started.
        config.id_generator = OpenTelemetry::Propagator::XRay::IDGenerator
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: endpoint(TestEnvironment.current.traces_telemetry_info, 'traces'))
        config.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))
      end

      def configure_metrics
        require 'opentelemetry/exporter/otlp_metrics'

        exporter = OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new(
          endpoint: endpoint(TestEnvironment.current.metrics_telemetry_info, 'metrics')
        )
        OpenTelemetry.meter_provider.add_metric_reader(
          OpenTelemetry::SDK::Metrics::Export::PeriodicMetricReader.new(exporter:, export_interval_millis: 5_000)
        )
      end

      def endpoint(telemetry_info, signal)
        raise "The test environment has no collector for #{signal}" if telemetry_info&.endpoint.nil?

        "http://#{telemetry_info.endpoint}:#{telemetry_info.endpoint_port}/v1/#{signal}"
      end

      def shutdown
        OpenTelemetry.tracer_provider.shutdown if traces_enabled?
        OpenTelemetry.meter_provider.shutdown if metrics_enabled?
      end
    end
  end
end
