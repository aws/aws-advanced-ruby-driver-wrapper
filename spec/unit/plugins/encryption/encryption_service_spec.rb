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
require 'bigdecimal'
require 'date'
require 'openssl'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/encryption_service'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::EncryptionService do
  let(:type_marker) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption::TypeMarker }
  let(:algorithms) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption::EncryptionAlgorithm }
  let(:encryption_error) { AwsAdvancedRubyDriverWrapper::Errors::EncryptionError }
  let(:data_key) { OpenSSL::Random.random_bytes(32) }
  let(:hmac_key) { OpenSSL::Random.random_bytes(32) }
  let(:key_id) { 7 }

  # Every value is tagged with the key_storage id it was encrypted under. Tests that do not care
  # about the id use a fixed one; the helper keeps the required key_id keyword out of every call.
  def encrypt_value(value, dkey = data_key, hkey = hmac_key, algorithm = nil, kid: key_id)
    if algorithm
      described_class.encrypt(value, dkey, hkey, algorithm, key_id: kid)
    else
      described_class.encrypt(value, dkey, hkey, key_id: kid)
    end
  end

  # Re-signs a payload whose body has been edited, so that a test can get past the integrity
  # check and exercise the decryption path itself.
  def resign(payload, key)
    body = payload.byteslice(described_class::HMAC_TAG_LENGTH..)
    "#{OpenSSL::HMAC.digest(described_class::HMAC_DIGEST, key, body)}#{body}".b
  end

  def round_trip(value, target_type: nil)
    described_class.decrypt(encrypt_value(value, data_key, hmac_key), data_key, hmac_key,
                            target_type: target_type)
  end

  describe 'the payload layout' do
    subject(:encrypted) { encrypt_value('hello', data_key, hmac_key) }

    it 'reserves 65 bytes for the framing' do
      expect(described_class::MIN_ENCRYPTED_LENGTH).to eq(65)
    end

    it 'is binary' do
      expect(encrypted.encoding).to eq(Encoding::BINARY)
    end

    it 'is the HMAC, the key id, the type marker, the IV, the ciphertext, and the GCM tag' do
      expect(encrypted.bytesize).to eq(32 + 4 + 1 + 12 + 'hello'.bytesize + 16)
    end

    it 'signs everything after the HMAC' do
      expect(encrypted.byteslice(0, 32))
        .to eq(OpenSSL::HMAC.digest('SHA256', hmac_key, encrypted.byteslice(32..)))
    end

    it 'records the key id ahead of the type marker' do
      expect(encrypted.byteslice(32, 4).unpack1('N')).to eq(key_id)
    end

    it 'records the type marker after the key id, ahead of the IV' do
      expect(encrypted.getbyte(32 + 4)).to eq(type_marker::STRING)
    end

    it 'uses a fresh IV for every value, so the same plaintext never repeats' do
      expect(encrypt_value('hello', data_key, hmac_key))
        .not_to eq(encrypt_value('hello', data_key, hmac_key))
    end
  end

  describe 'round trips' do
    it 'restores a string' do
      expect(round_trip('123-45-6789')).to eq('123-45-6789')
    end

    it 'restores a string as UTF-8' do
      expect(round_trip('héllo').encoding).to eq(Encoding::UTF_8)
      expect(round_trip('héllo')).to eq('héllo')
    end

    it 'restores an empty string' do
      expect(round_trip('')).to eq('')
    end

    it 'restores binary data as binary' do
      value = "\x00\x01\xfe\xff".b
      expect(round_trip(value)).to eq(value)
      expect(round_trip(value).encoding).to eq(Encoding::BINARY)
    end

    it 'restores an integer' do
      expect(round_trip(42)).to eq(42)
      expect(round_trip(-1)).to eq(-1)
      expect(round_trip(2**40)).to eq(2**40)
    end

    it 'restores a float' do
      expect(round_trip(1.5)).to eq(1.5)
      expect(round_trip(-0.125)).to eq(-0.125)
    end

    it 'restores booleans' do
      expect(round_trip(true)).to be(true)
      expect(round_trip(false)).to be(false)
    end

    it 'restores a BigDecimal' do
      expect(round_trip(BigDecimal('12345.6789'))).to eq(BigDecimal('12345.6789'))
    end

    # Timestamps are stored as epoch milliseconds, so sub-millisecond precision is lost.
    it 'restores a Time to the millisecond' do
      value = Time.at(1_754_899_200.123)
      expect(round_trip(value).to_f).to be_within(0.001).of(value.to_f)
    end

    it 'restores a Date' do
      expect(round_trip(Date.new(2026, 8, 11))).to eq(Date.new(2026, 8, 11))
    end

    it 'restores a DateTime' do
      expect(round_trip(DateTime.new(2026, 8, 11, 12, 30, 45))).to eq(DateTime.new(2026, 8, 11, 12, 30, 45))
    end

    it 'restores an unrecognized type through its string form' do
      expect(round_trip(:pending)).to eq('pending')
    end

    it 'passes nil straight through' do
      expect(encrypt_value(nil, data_key, hmac_key)).to be_nil
      expect(described_class.decrypt(nil, data_key, hmac_key)).to be_nil
    end

    it 'coerces to a requested target type' do
      expect(round_trip(42, target_type: String)).to eq('42')
    end

    it 'works with AES-128-GCM and a 16 byte key' do
      short_key = OpenSSL::Random.random_bytes(16)
      encrypted = encrypt_value('ssn', short_key, hmac_key, algorithms::AES_128_GCM)
      expect(described_class.decrypt(encrypted, short_key, hmac_key, algorithms::AES_128_GCM)).to eq('ssn')
    end

    it 'leaves the value it was given alone' do
      value = +'123-45-6789'
      encrypt_value(value, data_key, hmac_key)
      expect(value).to eq('123-45-6789')
    end
  end

  describe 'rejecting bad payloads' do
    it 'rejects a payload that is too short to hold the framing' do
      expect { described_class.decrypt('x' * 60, data_key, hmac_key) }
        .to raise_error(encryption_error, /too short: 60 bytes, expected at least 65/) do |error|
          expect(error.code).to eq(encryption_error::DECRYPTION_FAILED)
        end
    end

    it 'rejects a payload whose ciphertext has been edited' do
      encrypted = encrypt_value('123-45-6789', data_key, hmac_key)
      encrypted.setbyte(50, encrypted.getbyte(50) ^ 0xff)

      expect { described_class.decrypt(encrypted, data_key, hmac_key) }
        .to raise_error(encryption_error, /Integrity check failed: the encrypted value has been tampered with/)
    end

    it 'rejects a payload signed with a different HMAC key' do
      encrypted = encrypt_value('123-45-6789', data_key, hmac_key)

      expect { described_class.decrypt(encrypted, data_key, OpenSSL::Random.random_bytes(32)) }
        .to raise_error(encryption_error, /Integrity check failed/)
    end

    # The HMAC key alone does not prove the data key is right: GCM catches that.
    it 'rejects a correctly signed payload that was encrypted with a different data key' do
      encrypted = encrypt_value('123-45-6789', data_key, hmac_key)

      expect { described_class.decrypt(encrypted, OpenSSL::Random.random_bytes(32), hmac_key) }
        .to raise_error(encryption_error, /the authentication tag does not match this data key/) do |error|
          expect(error.context[:algorithm]).to eq(algorithms::AES_256_GCM)
        end
    end

    it 'rejects a payload carrying an unknown type marker' do
      encrypted = encrypt_value('123-45-6789', data_key, hmac_key)
      # The marker sits after the HMAC tag and the key id.
      encrypted.setbyte(described_class::HMAC_TAG_LENGTH + described_class::KEY_ID_LENGTH, 77)

      expect { described_class.decrypt(resign(encrypted, hmac_key), data_key, hmac_key) }
        .to raise_error(encryption_error, /Unknown type marker: 77/)
    end

    it 'rejects a data key of the wrong length' do
      expect { encrypt_value('x', OpenSSL::Random.random_bytes(16), hmac_key) }
        .to raise_error(encryption_error, /Data key must be 32 bytes for AES-256-GCM, got 16/) do |error|
          expect(error.code).to eq(encryption_error::INVALID_KEY)
        end
    end

    it 'rejects a missing data key' do
      expect { encrypt_value('x', nil, hmac_key) }
        .to raise_error(encryption_error, /Data key must be 32 bytes for AES-256-GCM, got nil/)
    end

    # The decrypt path validates the data key too, past the length check but before decrypting.
    it 'rejects a data key of the wrong length on the decrypt path' do
      encrypted = encrypt_value('123-45-6789', data_key, hmac_key)

      expect { described_class.decrypt(encrypted, OpenSSL::Random.random_bytes(16), hmac_key) }
        .to raise_error(encryption_error, /Data key must be 32 bytes for AES-256-GCM, got 16/) do |error|
          expect(error.code).to eq(encryption_error::INVALID_KEY)
        end
    end

    it 'rejects a missing HMAC key' do
      expect { encrypt_value('x', data_key, nil) }
        .to raise_error(encryption_error, /An HMAC key is required to protect encrypted values/)
      expect { encrypt_value('x', data_key, '') }
        .to raise_error(encryption_error, /An HMAC key is required/)
    end

    it 'rejects an unsupported algorithm' do
      expect { encrypt_value('x', data_key, hmac_key, 'AES_256_GCM') }
        .to raise_error(encryption_error, /Unsupported kms_encryption algorithm/)
    end
  end

  describe '.key_id_from_payload' do
    it 'reads back the key id a value was encrypted with' do
      expect(described_class.key_id_from_payload(encrypt_value('123-45-6789', data_key, hmac_key, kid: 4242)))
        .to eq(4242)
    end

    it 'is nil for a value too short to carry a key id' do
      expect(described_class.key_id_from_payload('x' * 20)).to be_nil
    end

    it 'is nil for nil' do
      expect(described_class.key_id_from_payload(nil)).to be_nil
    end
  end

  describe '.serialize_value' do
    it 'raises for a marker it cannot write' do
      expect { described_class.serialize_value('x', 12_345) }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::EncryptionError,
                        /Unsupported value type: String/) do |error|
        expect(error.context[:data_type]).to eq('String')
      end
    end
  end

  describe '.deserialize_value' do
    # These markers are never written by the Ruby wrapper but are written by the other AWS
    # Advanced Wrappers, so stored columns have to stay readable.
    it 'reads a 32 bit INTEGER' do
      expect(described_class.deserialize_value([42].pack('l>'), type_marker::INTEGER)).to eq(42)
    end

    it 'reads a 32 bit FLOAT' do
      expect(described_class.deserialize_value([1.5].pack('g'), type_marker::FLOAT)).to eq(1.5)
    end

    it 'reads a DATE as a Date' do
      millis = (Time.utc(2026, 8, 11).to_f * 1000).round
      expect(described_class.deserialize_value([millis].pack('q>'), type_marker::DATE))
        .to eq(Time.at(millis / 1000.0).to_date)
    end

    it 'reads a TIME as a Time' do
      millis = (Time.utc(2026, 8, 11, 12, 30, 45).to_f * 1000).round
      expect(described_class.deserialize_value([millis].pack('q>'), type_marker::TIME).to_f)
        .to be_within(0.001).of(millis / 1000.0)
    end

    # Ruby has no time-of-day type, so LOCAL_TIME is carried as its own string.
    it 'reads a LOCAL_TIME as a string' do
      bytes = described_class.serialize_value('12:30:45', type_marker::LOCAL_TIME)
      expect(described_class.deserialize_value(bytes, type_marker::LOCAL_TIME)).to eq('12:30:45')
    end

    it 'rejects a payload of the wrong width for its marker' do
      expect { described_class.deserialize_value('ab', type_marker::INTEGER) }
        .to raise_error(encryption_error, /Expected 4 bytes for INTEGER, got 2/)
    end

    it 'reports a value that cannot be parsed as its declared type' do
      expect { described_class.deserialize_value('not a number', type_marker::BIG_DECIMAL) }
        .to raise_error(encryption_error, /Failed to deserialize BIG_DECIMAL/) do |error|
          expect(error.code).to eq(encryption_error::TYPE_CONVERSION_FAILED)
        end
    end

    # An unparseable date fails the read rather than being handed back as a string, matching how the
    # numeric and BIG_DECIMAL markers behave (and the JDBC wrapper).
    it 'raises when a date cannot be parsed' do
      expect { described_class.deserialize_value('not a date', type_marker::LOCAL_DATE) }
        .to raise_error(encryption_error, /Failed to deserialize LOCAL_DATE/) do |error|
          expect(error.code).to eq(encryption_error::TYPE_CONVERSION_FAILED)
        end
    end

    it 'raises for a marker it cannot read' do
      expect { described_class.deserialize_value('x', 12_345) }
        .to raise_error(encryption_error, /Unsupported type marker: 12345/)
    end
  end

  describe '.convert_to_target_type' do
    it 'leaves the value alone when no type is requested' do
      expect(described_class.convert_to_target_type(42, nil)).to eq(42)
    end

    it 'leaves the value alone when it already is the requested type' do
      expect(described_class.convert_to_target_type('42', String)).to eq('42')
    end

    it 'passes nil through' do
      expect(described_class.convert_to_target_type(nil, String)).to be_nil
    end

    it 'converts to the requested type' do
      expect(described_class.convert_to_target_type(42, String)).to eq('42')
      expect(described_class.convert_to_target_type('42', Integer)).to eq(42)
      expect(described_class.convert_to_target_type('1.5', Float)).to eq(1.5)
      expect(described_class.convert_to_target_type('1.5', BigDecimal)).to eq(BigDecimal('1.5'))
      expect(described_class.convert_to_target_type('2026-08-11', Date)).to eq(Date.new(2026, 8, 11))
    end

    it 'converts a Time to a date or a DateTime without reparsing it' do
      time = Time.utc(2026, 8, 11, 12, 30, 45)
      expect(described_class.convert_to_target_type(time, Date)).to eq(Date.new(2026, 8, 11))
      expect(described_class.convert_to_target_type(time, DateTime)).to eq(time.to_datetime)
    end

    it 'reads the usual database spellings of a boolean' do
      %w[t true TRUE y yes 1].each do |value|
        expect(described_class.convert_to_target_type(value, TrueClass)).to be(true)
      end
      ['f', 'false', 'n', 'no', '0', ''].each do |value|
        expect(described_class.convert_to_target_type(value, TrueClass)).to be(false)
      end
    end

    it 'reports a value that cannot be converted' do
      expect { described_class.convert_to_target_type('abc', Integer) }
        .to raise_error(encryption_error, /Cannot convert String to Integer/) do |error|
          expect(error.code).to eq(encryption_error::TYPE_CONVERSION_FAILED)
          expect(error.context[:data_type]).to eq('Integer')
        end
    end

    it 'reports a type it does not know how to convert to' do
      expect { described_class.convert_to_target_type('abc', Array) }
        .to raise_error(encryption_error, /Cannot convert String to Array/)
    end

    # Ruby's Integer("1.5", 10) raises rather than truncating (unlike JDBC, which rounds), so
    # decrypting a stored Float with an Integer target type fails instead of silently coercing.
    it 'fails to convert a stored Float to an Integer target type' do
      expect { round_trip(1.5, target_type: Integer) }
        .to raise_error(encryption_error, /Cannot convert Float to Integer/) do |error|
          expect(error.code).to eq(encryption_error::TYPE_CONVERSION_FAILED)
          expect(error.context[:data_type]).to eq('Integer')
        end
    end
  end

  describe '.wipe' do
    it 'overwrites a mutable string in place' do
      buffer = +'a-plaintext-data-key'
      described_class.wipe(buffer)
      expect(buffer).to eq("\0" * 20)
    end

    it 'returns nil' do
      expect(described_class.wipe(+'secret')).to be_nil
    end

    # Best effort: a frozen key cannot be overwritten, and that is not worth failing a query over.
    it 'leaves a frozen string alone' do
      frozen = 'secret'
      expect(described_class.wipe(frozen)).to be_nil
      expect(frozen).to eq('secret')
    end

    it 'ignores anything that is not a string' do
      expect(described_class.wipe(nil)).to be_nil
      expect(described_class.wipe(42)).to be_nil
    end
  end
end
