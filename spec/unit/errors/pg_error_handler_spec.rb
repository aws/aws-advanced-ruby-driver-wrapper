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

require 'aws_advanced_ruby_driver_wrapper/errors/pg_error_handler'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/pg_driver_dialect'

RSpec.describe AwsAdvancedRubyDriverWrapper::Errors::PgErrorHandler do
  let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect.new }
  subject(:handler) { described_class.new(driver_dialect) }

  describe '#network_error_by_sql_state?' do
    it 'returns true for admin shutdown (57P01)' do
      expect(handler.network_error_by_sql_state?('57P01')).to be true
    end

    it 'returns true for crash shutdown (57P02)' do
      expect(handler.network_error_by_sql_state?('57P02')).to be true
    end

    it 'returns true for cannot connect now (57P03)' do
      expect(handler.network_error_by_sql_state?('57P03')).to be true
    end

    it 'returns true for system error prefix (58xxx)' do
      expect(handler.network_error_by_sql_state?('58000')).to be true
      expect(handler.network_error_by_sql_state?('58030')).to be true
    end

    it 'returns true for connection error prefix (08xxx)' do
      expect(handler.network_error_by_sql_state?('08001')).to be true
      expect(handler.network_error_by_sql_state?('08006')).to be true
    end

    it 'returns true for unexpected error prefix (99xxx)' do
      expect(handler.network_error_by_sql_state?('99000')).to be true
    end

    it 'returns true for config file error prefix (F0xxx)' do
      expect(handler.network_error_by_sql_state?('F0000')).to be true
    end

    it 'returns false for non-network states' do
      expect(handler.network_error_by_sql_state?('28000')).to be false
      expect(handler.network_error_by_sql_state?('25006')).to be false
    end
  end

  describe '#login_error_by_sql_state?' do
    it 'returns true for 08004 (SCRAM auth / no password)' do
      expect(handler.login_error_by_sql_state?('08004')).to be true
    end

    it 'returns true for 28P01 (invalid password)' do
      expect(handler.login_error_by_sql_state?('28P01')).to be true
    end

    it 'returns true for 28000 (PAM auth error)' do
      expect(handler.login_error_by_sql_state?('28000')).to be true
    end

    it 'returns false for non-login states' do
      expect(handler.login_error_by_sql_state?('08001')).to be false
      expect(handler.login_error_by_sql_state?('57P01')).to be false
    end
  end

  describe '#read_only_error_by_sql_state?' do
    it 'returns true for 25006' do
      expect(handler.read_only_error_by_sql_state?('25006')).to be true
    end

    it 'returns false for other states' do
      expect(handler.read_only_error_by_sql_state?('28000')).to be false
      expect(handler.read_only_error_by_sql_state?('HY000')).to be false
    end
  end

  describe '#network_error?' do
    it 'detects network error from exception' do
      error = build_pg_error('57P01')
      expect(handler.network_error?(error)).to be true
    end

    it 'returns false for non-network error' do
      error = build_pg_error('28000')
      expect(handler.network_error?(error)).to be false
    end

    it 'walks the cause chain' do
      cause = build_pg_error('08001')
      wrapper = build_error_with_cause(cause)
      expect(handler.network_error?(wrapper)).to be true
    end

    it 'returns false when sql_state is nil throughout chain' do
      error = StandardError.new('no sql state')
      expect(handler.network_error?(error)).to be false
    end

    it 'returns true for PG::ConnectionBad with unexpected eof' do
      error = PG::ConnectionBad.new('PQconsumeInput() SSL error: unexpected eof while reading')
      allow(error).to receive(:result).and_return(nil)
      expect(handler.network_error?(error)).to be true
    end

    it 'returns true for PG::ConnectionBad with connection closed unexpectedly' do
      error = PG::ConnectionBad.new('server closed the connection unexpectedly')
      allow(error).to receive(:result).and_return(nil)
      expect(handler.network_error?(error)).to be true
    end

    it 'returns true for PG::ConnectionBad with reset by peer' do
      error = PG::ConnectionBad.new('could not receive data from server: Connection reset by peer')
      allow(error).to receive(:result).and_return(nil)
      expect(handler.network_error?(error)).to be true
    end

    it 'returns false for PG::ConnectionBad with non-network message' do
      error = PG::ConnectionBad.new('database "nonexistent" does not exist')
      allow(error).to receive(:result).and_return(nil)
      expect(handler.network_error?(error)).to be false
    end

    # libpq discards the structured error fields for failures raised while connecting, so these all
    # arrive as a PG::ConnectionBad with no SQLSTATE and must be told apart by message alone.
    context 'when the connection attempt never reached a server' do
      {
        'a refused connection' => 'connection to server at "host", port 5432 failed: Connection refused',
        'a connect timeout' => 'connection to server at "host", port 5432 failed: timeout expired',
        'an unresolvable host name' => 'could not translate host name "host" to address: nodename nor servname provided, or not known',
        'an unreachable network' => 'connection to server at "host", port 5432 failed: Network is unreachable',
        'an unreachable host' => 'connection to server at "host", port 5432 failed: No route to host',
        'a missing unix socket' => 'connection to server on socket "/tmp/.s.PGSQL.5432" failed: No such file or directory'
      }.each do |description, message|
        it "returns true for #{description}" do
          error = PG::ConnectionBad.new(message)
          allow(error).to receive(:result).and_return(nil)
          expect(handler.network_error?(error)).to be true
        end
      end
    end

    # These reached a server that then refused the login. Retrying against another host cannot help,
    # so they must not be classified as network errors.
    context 'when a server was reached and rejected the connection' do
      # rubocop:disable-next Layout/LineLength
      {
        'a failed password' => 'connection to server at "host", port 5432 failed: FATAL:  password authentication failed for user "someone"',
        'a missing pg_hba entry' => 'connection to server at "host", port 5432 failed: FATAL:  no pg_hba.conf entry for host "1.2.3.4", user "someone"',
        'a pg_hba rejection' => 'connection to server at "host", port 5432 failed: FATAL:  pg_hba.conf rejects connection for host "1.2.3.4", user "someone"',
        'a missing database' => 'connection to server at "host", port 5432 failed: FATAL:  database "somedb" does not exist',
        'a missing role' => 'connection to server at "host", port 5432 failed: FATAL:  role "someone" does not exist',
        'an exhausted connection limit' => 'connection to server at "host", port 5432 failed: FATAL:  sorry, too many clients already'
      }.each do |description, message|
        it "returns false for #{description}" do
          error = PG::ConnectionBad.new(message)
          allow(error).to receive(:result).and_return(nil)
          expect(handler.network_error?(error)).to be false
        end
      end
    end
  end

  describe '#login_error?' do
    it 'detects login error from exception' do
      error = build_pg_error('28P01')
      expect(handler.login_error?(error)).to be true
    end

    it 'walks the cause chain' do
      cause = build_pg_error('28000')
      wrapper = build_error_with_cause(cause)
      expect(handler.login_error?(wrapper)).to be true
    end
  end

  describe '#read_only_error?' do
    it 'detects read-only error from exception' do
      error = build_pg_error('25006')
      expect(handler.read_only_error?(error)).to be true
    end

    it 'returns false for non-read-only error' do
      error = build_pg_error('28000')
      expect(handler.read_only_error?(error)).to be false
    end

    it 'walks the cause chain' do
      cause = build_pg_error('25006')
      wrapper = build_error_with_cause(cause)
      expect(handler.read_only_error?(wrapper)).to be true
    end
  end

  private

  def build_pg_error(sql_state)
    result = instance_double('PG::Result')
    allow(result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return(sql_state)
    error = PG::Error.new('test error')
    allow(error).to receive(:result).and_return(result)
    error
  end

  def build_error_with_cause(cause)
    begin
      raise cause
    rescue StandardError
      raise StandardError, 'wrapper error'
    end
  rescue StandardError => e
    e
  end
end
