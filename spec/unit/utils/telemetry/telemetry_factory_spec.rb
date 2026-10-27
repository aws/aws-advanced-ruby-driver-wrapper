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
require 'aws_advanced_ruby_driver_wrapper/utils/telemetry/telemetry_factory'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::Telemetry::TelemetryFactory do
  include TelemetryHelper

  let(:telemetry) { AwsAdvancedRubyDriverWrapper::Utils::Telemetry }
  let(:status_codes) { OpenTelemetry::Trace::Status }

  describe 'backend selection' do
    it 'records nothing when telemetry is not enabled' do
      factory = described_class.new({ telemetry_traces_backend: 'otlp', telemetry_metrics_backend: 'otlp' })

      expect(factory.in_use?).to be(false)
      expect(factory.open_telemetry_context('call', telemetry::TraceLevel::FORCE_TOP_LEVEL)).to be(telemetry::NullTelemetryContext::INSTANCE)
      expect(factory.create_counter('counter')).to be(telemetry::NullTelemetryCounter::INSTANCE)
      expect(factory.create_gauge('gauge') { 1 }).to be(telemetry::NullTelemetryGauge::INSTANCE)
    end

    it 'records traces and metrics through OpenTelemetry when both backends are otlp' do
      factory = described_class.new(telemetry_props)

      expect(factory.in_use?).to be(true)
      expect(factory.open_telemetry_context('call', telemetry::TraceLevel::NO_TRACE)).to be_a(telemetry::OpenTelemetryContext)
      expect(factory.create_counter('counter')).to be_a(telemetry::OpenTelemetryCounter)
    end

    it 'accepts backend names in any case' do
      factory = described_class.new(telemetry_props(telemetry_traces_backend: 'OTLP', telemetry_metrics_backend: 'None'))

      expect(factory.open_telemetry_context('call', telemetry::TraceLevel::NO_TRACE)).to be_a(telemetry::OpenTelemetryContext)
      expect(factory.create_counter('counter')).to be(telemetry::NullTelemetryCounter::INSTANCE)
    end

    it 'records metrics without traces when the traces backend is none' do
      factory = described_class.new(telemetry_props(telemetry_traces_backend: 'none'))

      expect(factory.in_use?).to be(true)
      expect(factory.open_telemetry_context('call', telemetry::TraceLevel::FORCE_TOP_LEVEL)).to be(telemetry::NullTelemetryContext::INSTANCE)
      expect(factory.create_counter('counter')).to be_a(telemetry::OpenTelemetryCounter)
    end

    it 'is not in use when telemetry is enabled with both backends set to none' do
      factory = described_class.new(telemetry_props(telemetry_traces_backend: 'none', telemetry_metrics_backend: 'none'))

      expect(factory.in_use?).to be(false)
    end

    it 'rejects a traces backend it does not recognize' do
      expect { described_class.new(telemetry_props(telemetry_traces_backend: 'xray')) }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /"xray" is not a valid telemetry_traces_backend.*otlp, none/)
    end

    it 'rejects a metrics backend it does not recognize' do
      expect { described_class.new(telemetry_props(telemetry_metrics_backend: 'statsd')) }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /"statsd" is not a valid telemetry_metrics_backend/)
    end

    it 'requires a value for each backend when telemetry is enabled, even if it is none' do
      expect { described_class.new({ enable_telemetry: true, telemetry_metrics_backend: 'none' }) }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /nil is not a valid telemetry_traces_backend/)
    end

    it 'reads its settings from string values, as they arrive in a connection URL' do
      factory = described_class.new({ enable_telemetry: 'true', telemetry_traces_backend: 'otlp', telemetry_metrics_backend: 'none' })

      expect(factory.in_use?).to be(true)
    end

    it 'explains which gem to add when the OpenTelemetry API is not installed' do
      allow(telemetry::OpenTelemetryFactory).to receive(:require).and_call_original
      allow(telemetry::OpenTelemetryFactory).to receive(:require).with('opentelemetry-api').and_raise(LoadError)

      expect { described_class.new(telemetry_props) }.to raise_error(LoadError, /gem 'opentelemetry-api'/)
    end

    it 'explains which gem to add when the OpenTelemetry metrics API is not installed' do
      allow(telemetry::OpenTelemetryFactory).to receive(:require).and_call_original
      allow(telemetry::OpenTelemetryFactory).to receive(:require).with('opentelemetry-metrics-api').and_raise(LoadError)

      expect { described_class.new(telemetry_props) }.to raise_error(LoadError, /gem 'opentelemetry-metrics-api'/)
    end

    it 'does not load the OpenTelemetry gems when telemetry is not enabled' do
      allow(telemetry::OpenTelemetryFactory).to receive(:require)

      described_class.new({})

      expect(telemetry::OpenTelemetryFactory).not_to have_received(:require)
    end
  end

  describe 'trace levels' do
    let(:factory) { described_class.new(telemetry_props(telemetry_submit_top_level: submit_top_level)) }
    let(:submit_top_level) { false }

    def open_and_close(name, trace_level)
      factory.in_context(name, trace_level) { nil }
    end

    context 'with a nested context' do
      it 'records nothing outside of a trace' do
        open_and_close('wrapper call', telemetry::TraceLevel::NESTED)

        expect(finished_spans).to be_empty
      end

      it 'records a child of the current span inside a trace' do
        in_application_span { open_and_close('wrapper call', telemetry::TraceLevel::NESTED) }

        child = span_named('wrapper call')
        parent = span_named('application')
        expect(child.trace_id).to eq(parent.trace_id)
        expect(child.parent_span_id).to eq(parent.span_id)
        expect(child.attributes).to include('trace_name' => 'wrapper call')
      end

      it 'makes its span the parent of the spans opened inside it' do
        in_application_span do
          factory.in_context('outer', telemetry::TraceLevel::NESTED) { open_and_close('inner', telemetry::TraceLevel::NESTED) }
        end

        expect(span_named('inner').parent_span_id).to eq(span_named('outer').span_id)
      end

      it 'restores the span that was current before it was opened' do
        in_application_span do |application_span|
          open_and_close('wrapper call', telemetry::TraceLevel::NESTED)

          expect(OpenTelemetry::Trace.current_span).to eq(application_span)
        end
      end
    end

    context 'with a top-level context when telemetry_submit_top_level is disabled' do
      it 'is recorded as a nested context' do
        open_and_close('outside', telemetry::TraceLevel::TOP_LEVEL)
        in_application_span { open_and_close('inside', telemetry::TraceLevel::TOP_LEVEL) }

        expect(span_named('outside')).to be_nil
        expect(span_named('inside').parent_span_id).to eq(span_named('application').span_id)
      end
    end

    context 'with a top-level context when telemetry_submit_top_level is enabled' do
      let(:submit_top_level) { true }

      it 'starts a trace outside of any trace' do
        open_and_close('wrapper call', telemetry::TraceLevel::TOP_LEVEL)

        span = span_named('wrapper call')
        expect(span.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
        expect(span.attributes).to eq('trace_name' => 'wrapper call')
        expect(span.links).to be_nil
      end

      it 'starts a trace of its own inside a trace, linked to the one in progress' do
        in_application_span { open_and_close('wrapper call', telemetry::TraceLevel::TOP_LEVEL) }

        span = span_named('wrapper call')
        application = span_named('application')
        expect(span.trace_id).not_to eq(application.trace_id)
        expect(span.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
        expect(span.links.map { |link| link.span_context.span_id }).to eq([application.span_id])
        expect(span.attributes).to include('parent_trace_id' => application.hex_trace_id, 'trace_name' => 'wrapper call')
      end
    end

    context 'with a forced top-level context' do
      it 'starts a trace even when telemetry_submit_top_level is disabled' do
        open_and_close('wrapper call', telemetry::TraceLevel::FORCE_TOP_LEVEL)

        expect(span_named('wrapper call').parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
      end
    end

    context 'with no trace' do
      it 'records nothing, even inside a trace' do
        in_application_span { open_and_close('wrapper call', telemetry::TraceLevel::NO_TRACE) }

        expect(finished_spans.map(&:name)).to eq(['application'])
      end
    end
  end

  describe '#in_context' do
    let(:factory) { described_class.new(telemetry_props(telemetry_submit_top_level: true)) }

    it 'returns the result of the block' do
      expect(factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL) { 42 }).to eq(42)
    end

    it 'leaves the status of the span unset unless asked to record the result' do
      factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL) { nil }

      expect(span_named('call').status.code).to eq(status_codes::UNSET)
    end

    it 'marks the span as succeeded when the block returns' do
      factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL, record_result: true) { nil }

      expect(span_named('call').status.code).to eq(status_codes::OK)
    end

    it 'marks the span as failed and records the error when the block raises' do
      expect do
        factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL, record_result: true) { raise ArgumentError, 'bad argument' }
      end.to raise_error(ArgumentError, 'bad argument')

      span = span_named('call')
      expect(span.status.code).to eq(status_codes::ERROR)
      expect(span.attributes).to include('exception_type' => 'ArgumentError', 'exception_message' => 'bad argument')
      expect(span.events.map(&:name)).to eq(['exception'])
    end

    it 'closes the span when the block raises without recording the error unless asked to' do
      expect { factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL) { raise ArgumentError } }.to raise_error(ArgumentError)

      span = span_named('call')
      expect(span.status.code).to eq(status_codes::UNSET)
      expect(span.events).to be_nil
      expect(OpenTelemetry::Trace.current_span).to eq(OpenTelemetry::Trace::Span::INVALID)
    end

    it 'yields a context whose attributes are recorded on the span' do
      factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL) { |context| context.set_attribute('ruby_call', 'connection.query') }

      expect(span_named('call').attributes).to include('ruby_call' => 'connection.query')
    end

    it 'with record_failure, leaves the status of the span unset when the block returns' do
      factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL, record_failure: true) { nil }

      expect(span_named('call').status.code).to eq(status_codes::UNSET)
    end

    it 'with record_failure, marks the span as failed and records the error when the block raises' do
      expect do
        factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL, record_failure: true) do
          raise IOError, 'lost'
        end
      end.to raise_error(IOError)

      span = span_named('call')
      expect(span.status.code).to eq(status_codes::ERROR)
      expect(span.attributes).to include('exception_type' => 'IOError', 'exception_message' => 'lost')
    end

    it 'marks the span as succeeded when the block is left early' do
      factory.in_context('call', telemetry::TraceLevel::TOP_LEVEL, record_result: true) { break }

      expect(span_named('call').status.code).to eq(status_codes::OK)
      expect(OpenTelemetry::Trace.current_span).to eq(OpenTelemetry::Trace::Span::INVALID)
    end

    it 'yields the null context when traces are not recorded' do
      factory = described_class.new({})

      expect { |block| factory.in_context('call', telemetry::TraceLevel::FORCE_TOP_LEVEL, &block) }
        .to yield_with_args(telemetry::NullTelemetryContext::INSTANCE)
    end
  end

  describe '#post_copy' do
    let(:factory) { described_class.new(telemetry_props) }

    def failover_context
      context = nil
      in_application_span do
        factory.in_context('failover', telemetry::TraceLevel::NESTED) do |ctx|
          context = ctx
          ctx.set_attribute('host', 'instance-1')
          ctx.success = true
        end
      end
      context
    end

    it 'records a top-level copy of the span, with the same timings, attributes and status' do
      factory.post_copy(failover_context, telemetry::TraceLevel::FORCE_TOP_LEVEL)

      original = span_named('failover')
      copy = span_named('copy: failover')
      expect(copy.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
      expect(copy.trace_id).not_to eq(original.trace_id)
      expect([copy.start_timestamp, copy.end_timestamp]).to eq([original.start_timestamp, original.end_timestamp])
      expect(copy.status.code).to eq(OpenTelemetry::Trace::Status::OK)
      expect(copy.attributes).to include('host' => 'instance-1', 'trace_name' => 'copy: failover',
                                         'source_trace_id' => original.hex_trace_id)
    end

    it 'links the copy only to the span it copies, not to the trace in progress' do
      in_application_span { factory.post_copy(failover_context, telemetry::TraceLevel::FORCE_TOP_LEVEL) }

      copy = span_named('copy: failover')
      expect(copy.links.map { |link| link.span_context.span_id }).to eq([span_named('failover').span_id])
      expect(copy.attributes).not_to include('parent_trace_id')
    end

    it 'records a nested copy as a child of the current span' do
      context = failover_context
      in_application_span { factory.post_copy(context, telemetry::TraceLevel::NESTED) }

      application = finished_spans.reverse.find { |span| span.name == 'application' }
      expect(span_named('copy: failover').parent_span_id).to eq(application.span_id)
    end

    it 'records nothing for the no_trace level' do
      context = failover_context
      expect { factory.post_copy(context, telemetry::TraceLevel::NO_TRACE) }.not_to(change { finished_spans.size })
    end

    it 'does nothing for a span that is not recording, such as one that was not sampled' do
      unrecorded = telemetry::OpenTelemetryContext.new(OpenTelemetry::Trace::Tracer.new, 'failover', telemetry::TraceLevel::FORCE_TOP_LEVEL)
      unrecorded.close

      expect { factory.post_copy(unrecorded, telemetry::TraceLevel::FORCE_TOP_LEVEL) }.not_to(change { finished_spans.size })
    end

    it 'does nothing for a context that recorded no span' do
      expect { factory.post_copy(telemetry::NullTelemetryContext::INSTANCE, telemetry::TraceLevel::FORCE_TOP_LEVEL) }
        .not_to(change { finished_spans.size })
    end

    it 'does nothing when traces are not recorded' do
      untraced = described_class.new({})

      expect { untraced.post_copy(failover_context, telemetry::TraceLevel::FORCE_TOP_LEVEL) }.not_to raise_error
    end
  end

  describe 'metrics' do
    let(:factory) { described_class.new(telemetry_props) }

    def metric_named(name)
      collect_metrics.find { |metric| metric.name == name }
    end

    it 'counts what is added to a counter' do
      counter = factory.create_counter('test.counter.added')
      counter.inc
      counter.add(4)

      metric = metric_named('test.counter.added')
      expect(metric.instrument_kind).to eq(:counter)
      expect(metric.data_points.map(&:value)).to eq([5])
    end

    it 'reads a gauge from its callback when metrics are collected' do
      value = 3
      factory.create_gauge('test.gauge.read') { value }
      value = 7

      metric = metric_named('test.gauge.read')
      expect(metric.instrument_kind).to eq(:observable_gauge)
      expect(metric.data_points.map(&:value)).to eq([7])
    end

    it 'reads a gauge created again with the same name, by any connection, from the newest callback' do
      first_gauge = factory.create_gauge('test.gauge.replaced') { 1 }
      second_gauge = described_class.new(telemetry_props).create_gauge('test.gauge.replaced') { 2 }

      expect(second_gauge).to be(first_gauge)
      expect(metric_named('test.gauge.replaced').data_points.map(&:value)).to eq([2])
    end

    it 'stops reading the callback a gauge was created with once it is replaced' do
      first_callback_calls = 0
      factory.create_gauge('test.gauge.stale') { first_callback_calls += 1 }
      factory.create_gauge('test.gauge.stale') { 5 }

      collect_metrics

      expect(first_callback_calls).to eq(0)
    end

    it 'trims metric names to the length OpenTelemetry allows' do
      counter = factory.create_counter("test.#{'a' * 300}")

      expect(counter.name.length).to eq(255)
    end
  end
end
