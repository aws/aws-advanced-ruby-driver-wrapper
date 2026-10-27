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

require 'trilogy'
require 'aws_advanced_ruby_driver_wrapper/errors/trilogy_error_handler'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/trilogy_driver_dialect'

RSpec.describe AwsAdvancedRubyDriverWrapper::Errors::TrilogyErrorHandler do
  let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::TrilogyDriverDialect.new }
  subject(:handler) { described_class.new(driver_dialect) }

  describe '#network_error?' do
    {
      'a read or write timeout' => -> { Trilogy::TimeoutError.new('trilogy_query_recv') },
      'an EOF on the socket' => -> { Trilogy::EOFError.new('TRILOGY_CLOSED_CONNECTION') },
      'a reset connection' => -> { Trilogy::SyscallError::ECONNRESET.new('trilogy_query_send') },
      'a refused connection' => -> { Trilogy::SyscallError::ECONNREFUSED.new('connect') },
      'a TLS failure' => -> { Trilogy::SSLError.new('SSL Error: unexpected eof') },
      'a DNS failure' => -> { Trilogy::BaseConnectionError.new('trilogy_connect: TRILOGY_DNS_ERROR') },
      'a connection killed by the server (1927)' => -> { Trilogy::ProtocolError.from_code('killed', 1927) },
      'a disconnect by the server (4031)' => -> { Trilogy::ProtocolError.from_code('disconnected', 4031) },
      'a network read error reported by the server (1158)' => -> { Trilogy::ProtocolError.from_code('read', 1158) }
    }.each do |description, build|
      it "is true for #{description}" do
        expect(handler.network_error?(build.call)).to be true
      end
    end

    # Trilogy files these under ConnectionError too, but none of them means the server is unreachable,
    # so treating them as network errors would fail over on a wrong password or a busy row.
    {
      'rejected credentials (1045)' => -> { Trilogy::ProtocolError.from_code('access denied', 1045) },
      'a database the user may not access (1044)' => -> { Trilogy::ProtocolError.from_code('access denied', 1044) },
      'a lock wait timeout (1205)' => -> { Trilogy::ProtocolError.from_code('lock wait timeout', 1205) },
      # An IAM token is sent with mysql_clear_password, which trilogy refuses unless
      # enable_cleartext_plugin is set: a configuration error, not an unreachable server.
      'an authentication plugin trilogy will not use' => -> { Trilogy::AuthPluginError.new('TRILOGY_AUTH_PLUGIN_ERROR') },
      'a connection the application closed itself' => -> { Trilogy::ConnectionClosed.new('closed') }
    }.each do |description, build|
      it "is false for #{description}" do
        expect(handler.network_error?(build.call)).to be false
      end
    end

    it 'is false for a query error' do
      expect(handler.network_error?(Trilogy::ProtocolError.from_code('syntax', 1064))).to be false
    end

    it 'is false for an error that is not from trilogy' do
      expect(handler.network_error?(StandardError.new('boom'))).to be false
    end

    it 'walks the cause chain' do
      expect(handler.network_error?(error_with_cause(Trilogy::EOFError.new('eof')))).to be true
    end
  end

  describe '#login_error?' do
    it 'is true for rejected credentials (1045)' do
      expect(handler.login_error?(Trilogy::ProtocolError.from_code('access denied', 1045))).to be true
    end

    it 'is true for a database the user may not access (1044)' do
      expect(handler.login_error?(Trilogy::ProtocolError.from_code('access denied', 1044))).to be true
    end

    it 'is false for a network error' do
      expect(handler.login_error?(Trilogy::EOFError.new('eof'))).to be false
    end

    it 'walks the cause chain' do
      cause = Trilogy::ProtocolError.from_code('access denied', 1045)
      expect(handler.login_error?(error_with_cause(cause))).to be true
    end

    # trilogy raises these as a codeless Trilogy::QueryError, its message being the call that failed
    # and the trilogy error name.
    context 'with a protocol violation' do
      it 'is true while the server answers the authentication' do
        expect(handler.login_error?(Trilogy::QueryError.new('trilogy_auth_recv: TRILOGY_PROTOCOL_VIOLATION'))).to be true
      end

      it 'is false after the connection is established' do
        expect(handler.login_error?(Trilogy::QueryError.new('trilogy_query_recv: TRILOGY_PROTOCOL_VIOLATION'))).to be false
      end

      it 'is not a network error' do
        expect(handler.network_error?(Trilogy::QueryError.new('trilogy_auth_recv: TRILOGY_PROTOCOL_VIOLATION'))).to be false
      end
    end

    it 'is false for any other failure while the server answers the authentication' do
      expect(handler.login_error?(Trilogy::QueryError.new('trilogy_auth_recv: TRILOGY_UNEXPECTED_PACKET'))).to be false
    end
  end

  describe '#read_only_error?' do
    it 'is true for a write rejected by --read-only (1290)' do
      expect(handler.read_only_error?(Trilogy::ProtocolError.from_code('read only', 1290))).to be true
    end

    it 'is true for a write rejected by super_read_only (1836)' do
      expect(handler.read_only_error?(Trilogy::ProtocolError.from_code('read only', 1836))).to be true
    end

    it 'is false for other server errors' do
      expect(handler.read_only_error?(Trilogy::ProtocolError.from_code('syntax', 1064))).to be false
    end

    it 'walks the cause chain' do
      cause = Trilogy::ProtocolError.from_code('read only', 1836)
      expect(handler.read_only_error?(error_with_cause(cause))).to be true
    end
  end

  private

  def error_with_cause(cause)
    begin
      raise cause
    rescue StandardError
      raise StandardError, 'wrapper error'
    end
  rescue StandardError => e
    e
  end
end
