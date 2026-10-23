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

# Installs an OpenTelemetry SDK that keeps what it records in memory, the way an application would
# install one with real exporters. The SDK is installed once for the whole run, since OpenTelemetry's
# global providers are meant to be set once per process; the recordings are cleared between examples.
module TelemetryHelper
  class << self
    def span_exporter
      install
      @span_exporter
    end

    def metric_exporter
      install
      @metric_exporter
    end

    private

    def install
      return if @installed

      require 'opentelemetry/sdk'
      require 'opentelemetry-metrics-sdk'

      @span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      tracer_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@span_exporter))
      OpenTelemetry.tracer_provider = tracer_provider

      @metric_exporter = OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new
      meter_provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
      meter_provider.add_metric_reader(@metric_exporter)
      OpenTelemetry.meter_provider = meter_provider

      @installed = true
    end
  end

  def telemetry_props(**overrides)
    { enable_telemetry: true, telemetry_traces_backend: 'otlp', telemetry_metrics_backend: 'otlp' }.merge(overrides)
  end

  # @return [Array<OpenTelemetry::SDK::Trace::SpanData>] the spans finished so far, in the order they finished
  def finished_spans
    TelemetryHelper.span_exporter.finished_spans
  end

  def span_named(name)
    finished_spans.find { |span| span.name == name }
  end

  # @return [Array<OpenTelemetry::SDK::Metrics::State::MetricData>] the metrics collected now
  def collect_metrics
    TelemetryHelper.metric_exporter.pull
    TelemetryHelper.metric_exporter.metric_snapshots
  end

  # Runs the block inside a span of the application's own, as an instrumented application would.
  def in_application_span(name = 'application', &)
    OpenTelemetry.tracer_provider.tracer('application').in_span(name, &)
  end

  def self.included(base)
    base.before do
      TelemetryHelper.span_exporter.reset
      TelemetryHelper.metric_exporter.reset
    end
  end
end
