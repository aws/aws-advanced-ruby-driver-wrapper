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

require 'bigdecimal'
require 'date'
require 'openssl'
require 'securerandom'
require 'time'
require_relative 'encryption_algorithm'
require_relative 'errors'
require_relative 'type_marker'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # Encrypts and decrypts single column values with AES-GCM, signed with a separate
      # HMAC-SHA256 key.
      #
      # The payload written to the database is:
      #
      #   [ HMAC-SHA256 tag : 32 ][ key id : 4 ][ type marker : 1 ][ GCM IV : 12 ][ ciphertext ][ GCM tag : 16 ]
      #
      # The HMAC covers everything after itself, which lets the database verify that a payload
      # has not been tampered with (see the +verify_encrypted_data_hmac+ SQL function) without
      # ever holding the data key. The key id records which +key_storage+ row the value was
      # encrypted with, so a value stays decryptable after its column's data key has been rotated
      # (the read path resolves that exact key rather than assuming the column's current one); it
      # is inside the HMAC-covered region, so tampering with it is detected. The type marker records
      # how the plaintext was serialized so that the original Ruby type can be recovered on read.
      module EncryptionService
        HMAC_DIGEST = 'SHA256'
        HMAC_TAG_LENGTH = 32
        KEY_ID_LENGTH = 4
        TYPE_MARKER_LENGTH = 1
        GCM_IV_LENGTH = 12
        GCM_TAG_LENGTH = 16
        MIN_ENCRYPTED_LENGTH = HMAC_TAG_LENGTH + KEY_ID_LENGTH + TYPE_MARKER_LENGTH + GCM_IV_LENGTH + GCM_TAG_LENGTH

        MILLIS_PER_SECOND = 1000.0

        class << self
          # Encrypts a single value.
          #
          # @param value [Object, nil] the plaintext value; nil is returned unchanged
          # @param data_key [String] the plaintext data key, binary
          # @param hmac_key [String] the HMAC-SHA256 key, binary
          # @param algorithm [String] an {EncryptionAlgorithm} name
          # @param key_id [Integer] the +key_storage+ id of the data key, recorded in the payload so
          #   the value stays decryptable after the column's key is rotated
          # @return [String, nil] the binary payload to store, or nil when value is nil
          # @raise [Errors::EncryptionError] if the key or algorithm is unusable, or the cipher fails
          def encrypt(value, data_key, hmac_key, algorithm = EncryptionAlgorithm::DEFAULT, key_id:)
            return nil if value.nil?

            validate_key!(data_key, algorithm)
            validate_hmac_key!(hmac_key)
            validate_key_id!(key_id)

            marker = TypeMarker.from_object(value)
            plaintext = serialize_value(value, marker)

            begin
              # body = [ key id : 4 ][ type marker : 1 ][ IV : 12 ][ ciphertext ][ GCM tag : 16 ]
              body = "#{[key_id].pack('N')}#{seal(plaintext, marker, data_key, algorithm)}".b
              "#{OpenSSL::HMAC.digest(HMAC_DIGEST, hmac_key, body)}#{body}".b
            ensure
              wipe(plaintext)
            end
          end

          # Reads the key id recorded in a payload, without verifying or decrypting it. Used to pick
          # the key a stored value was written with before its HMAC is checked; a payload with no key
          # id (too short, or written before this format existed) yields nil.
          #
          # @param encrypted [String, nil] the binary payload read from the database
          # @return [Integer, nil]
          def key_id_from_payload(encrypted)
            return nil if encrypted.nil?

            data = encrypted.b
            return nil if data.bytesize < HMAC_TAG_LENGTH + KEY_ID_LENGTH

            data.byteslice(HMAC_TAG_LENGTH, KEY_ID_LENGTH).unpack1('N')
          end

          # Decrypts a payload produced by {encrypt}.
          #
          # @param encrypted [String, nil] the binary payload read from the database
          # @param data_key [String] the plaintext data key, binary
          # @param hmac_key [String] the HMAC-SHA256 key, binary
          # @param algorithm [String] an {EncryptionAlgorithm} name
          # @param target_type [Class, nil] the type to coerce the result to; defaults to the type
          #   recorded by the payload's type marker
          # @return [Object, nil] the decrypted value, or nil when encrypted is nil
          # @raise [Errors::EncryptionError] if the payload is malformed, has been tampered with,
          #   or cannot be decrypted with the given key
          def decrypt(encrypted, data_key, hmac_key, algorithm = EncryptionAlgorithm::DEFAULT, target_type: nil)
            return nil if encrypted.nil?

            data = encrypted.b
            if data.bytesize < MIN_ENCRYPTED_LENGTH
              raise Errors::EncryptionError.integrity_check_failed(
                "Encrypted data is too short: #{data.bytesize} bytes, expected at least #{MIN_ENCRYPTED_LENGTH}"
              ).with_algorithm(algorithm)
            end

            validate_key!(data_key, algorithm)
            validate_hmac_key!(hmac_key)

            # The HMAC covers the key id and everything after it; strip the key id once verified to
            # recover the sealed payload the marker, IV, ciphertext and tag live in.
            body = data.byteslice(HMAC_TAG_LENGTH..)
            unless hmac_matches?(data.byteslice(0, HMAC_TAG_LENGTH), body, hmac_key)
              raise Errors::EncryptionError
                .integrity_check_failed('Integrity check failed: the encrypted value has been tampered with')
                .with_algorithm(algorithm)
            end

            payload = body.byteslice(KEY_ID_LENGTH..)
            marker = read_marker(payload)
            plaintext = unseal(payload, data_key, algorithm, marker)

            begin
              convert_to_target_type(deserialize_value(plaintext, marker), target_type)
            ensure
              wipe(plaintext)
            end
          end

          # Serializes a value to the bytes that get encrypted.
          #
          # @param value [Object]
          # @param marker [Integer] a {TypeMarker}
          # @return [String] binary
          def serialize_value(value, marker = TypeMarker.from_object(value))
            case marker
            # Ruby has no time-of-day type, so a LOCAL_TIME value is serialized as its own string.
            when TypeMarker::STRING, TypeMarker::GENERIC, TypeMarker::LOCAL_TIME then utf8_bytes(value.to_s)
            when TypeMarker::BYTE_ARRAY then value.b
            when TypeMarker::INTEGER then [value].pack('l>')
            when TypeMarker::LONG then [value].pack('q>')
            when TypeMarker::DOUBLE then [value].pack('G')
            when TypeMarker::FLOAT then [value].pack('g')
            when TypeMarker::BOOLEAN then (value ? 1 : 0).chr
            when TypeMarker::BIG_DECIMAL then value.to_s('F').b
            when TypeMarker::DATE, TypeMarker::TIME, TypeMarker::TIMESTAMP then [to_millis(value)].pack('q>')
            when TypeMarker::LOCAL_DATE then value.strftime('%Y-%m-%d').b
            when TypeMarker::LOCAL_DATE_TIME then value.strftime('%Y-%m-%dT%H:%M:%S').b
            else
              raise Errors::EncryptionError
                .encryption_failed("Unsupported value type: #{value.class}")
                .with_data_type(value.class.to_s)
            end
          end

          # Turns decrypted bytes back into a Ruby value.
          #
          # Ruby has no time-of-day type, so {TypeMarker::LOCAL_TIME} payloads are returned as
          # their original string.
          #
          # @param bytes [String] binary
          # @param marker [Integer] a {TypeMarker}
          # @return [Object]
          def deserialize_value(bytes, marker)
            case marker
            when TypeMarker::STRING, TypeMarker::GENERIC, TypeMarker::LOCAL_TIME then utf8(bytes)
            when TypeMarker::BYTE_ARRAY then bytes.dup
            when TypeMarker::INTEGER then expect_length(bytes, 4, marker).unpack1('l>')
            when TypeMarker::LONG then expect_length(bytes, 8, marker).unpack1('q>')
            when TypeMarker::DOUBLE then expect_length(bytes, 8, marker).unpack1('G')
            when TypeMarker::FLOAT then expect_length(bytes, 4, marker).unpack1('g')
            when TypeMarker::BOOLEAN then expect_length(bytes, 1, marker).getbyte(0) != 0
            when TypeMarker::BIG_DECIMAL then BigDecimal(utf8(bytes))
            when TypeMarker::DATE then from_millis(expect_length(bytes, 8, marker).unpack1('q>')).to_date
            when TypeMarker::TIME, TypeMarker::TIMESTAMP then from_millis(expect_length(bytes, 8, marker).unpack1('q>'))
            when TypeMarker::LOCAL_DATE then Date.parse(utf8(bytes))
            when TypeMarker::LOCAL_DATE_TIME then DateTime.parse(utf8(bytes))
            else
              raise Errors::EncryptionError
                .decryption_failed("Unsupported type marker: #{marker.inspect}")
                .with_data_type(marker.to_s)
            end
          rescue ArgumentError, TypeError => e
            raise Errors::EncryptionError
              .type_conversion_failed("Failed to deserialize #{TypeMarker.name_for(marker) || marker}: #{e.message}")
              .with_data_type(TypeMarker.name_for(marker))
          end

          # Coerces a deserialized value to an explicitly requested type.
          #
          # @param value [Object, nil]
          # @param target_type [Class, nil] nil leaves the value as deserialized
          # @return [Object, nil]
          # @raise [Errors::EncryptionError] if the value cannot be coerced
          def convert_to_target_type(value, target_type)
            return value if target_type.nil? || value.nil?
            return value if value.is_a?(target_type)

            coerce(value, target_type)
          rescue ArgumentError, TypeError => e
            raise Errors::EncryptionError
              .type_conversion_failed("Cannot convert #{value.class} to #{target_type}: #{e.message}")
              .with_data_type(target_type.to_s)
          end

          # Overwrites a mutable string in place. Best effort: frozen strings are left alone.
          #
          # @param buffer [String, nil]
          # @return [nil]
          def wipe(buffer)
            return nil unless buffer.is_a?(String)
            return nil if buffer.frozen?

            buffer.replace("\0" * buffer.bytesize)
            nil
          rescue RuntimeError
            # FrozenError is a RuntimeError: a string can be frozen between the check and the
            # replace, and a key that cannot be wiped is not worth failing a query over.
            nil
          end

          private

          # @return [String] the type marker, IV, ciphertext, and GCM tag, without the HMAC
          def seal(plaintext, marker, data_key, algorithm)
            iv = SecureRandom.bytes(GCM_IV_LENGTH)
            cipher = OpenSSL::Cipher.new(EncryptionAlgorithm.cipher_name(algorithm))
            cipher.encrypt
            cipher.key = data_key
            cipher.iv = iv
            "#{marker.chr}#{iv}#{cipher.update(plaintext)}#{cipher.final}#{cipher.auth_tag(GCM_TAG_LENGTH)}"
          rescue OpenSSL::OpenSSLError => e
            raise Errors::EncryptionError
              .encryption_failed("Failed to encrypt value: #{e.message}")
              .with_algorithm(algorithm)
              .with_data_type(TypeMarker.name_for(marker))
          end

          # @return [String] the decrypted plaintext bytes
          def unseal(payload, data_key, algorithm, marker)
            iv = payload.byteslice(TYPE_MARKER_LENGTH, GCM_IV_LENGTH)
            body = payload.byteslice((TYPE_MARKER_LENGTH + GCM_IV_LENGTH)..)
            cipher = OpenSSL::Cipher.new(EncryptionAlgorithm.cipher_name(algorithm))
            cipher.decrypt
            cipher.key = data_key
            cipher.iv = iv
            cipher.auth_tag = body.byteslice(body.bytesize - GCM_TAG_LENGTH, GCM_TAG_LENGTH)
            cipher.update(body.byteslice(0, body.bytesize - GCM_TAG_LENGTH)) + cipher.final
          rescue OpenSSL::OpenSSLError => e
            # The payload's HMAC has already been checked by the time unseal runs, so a GCM failure
            # here means the data key is wrong rather than the data being corrupt. OpenSSL words that
            # failure differently across versions - an empty message on older ones, "AEAD
            # authentication tag verification failed" on newer - so both are reported the same way.
            raise Errors::EncryptionError
              .decryption_failed("Failed to decrypt value: #{gcm_failure_reason(e)}")
              .with_algorithm(algorithm)
              .with_data_type(TypeMarker.name_for(marker))
          end

          # @return [String] the reason to report for an OpenSSL failure during decryption
          def gcm_failure_reason(error)
            message = error.message.to_s
            return message unless message.empty? || message.match?(/auth|tag|verif/i)

            'the authentication tag does not match this data key'
          end

          def coerce(value, target_type)
            if target_type == String then value.to_s
            elsif target_type == Integer then Integer(value.to_s, 10)
            elsif target_type == Float then Float(value.to_s)
            elsif target_type == BigDecimal then BigDecimal(value.to_s)
            elsif target_type == Date then value.is_a?(Time) ? value.to_date : Date.parse(value.to_s)
            elsif target_type == DateTime then value.is_a?(Time) ? value.to_datetime : DateTime.parse(value.to_s)
            elsif target_type == Time then value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
            elsif [TrueClass, FalseClass].include?(target_type) then truthy?(value)
            else
              raise Errors::EncryptionError
                .type_conversion_failed("Cannot convert #{value.class} to #{target_type}")
                .with_data_type(target_type.to_s)
            end
          end

          def read_marker(payload)
            TypeMarker.from_value(payload.getbyte(0))
          rescue ArgumentError => e
            raise Errors::EncryptionError.decryption_failed(e.message)
          end

          def hmac_matches?(expected, payload, hmac_key)
            actual = OpenSSL::HMAC.digest(HMAC_DIGEST, hmac_key, payload)
            OpenSSL.fixed_length_secure_compare(expected, actual)
          rescue ArgumentError
            false
          end

          def validate_key!(data_key, algorithm)
            expected = EncryptionAlgorithm.key_length(algorithm)
            return if data_key.is_a?(String) && data_key.bytesize == expected

            raise Errors::EncryptionError
              .invalid_key("Data key must be #{expected} bytes for #{algorithm}, got #{data_key&.bytesize.inspect}")
              .with_algorithm(algorithm)
          end

          def validate_hmac_key!(hmac_key)
            return if hmac_key.is_a?(String) && !hmac_key.empty?

            raise Errors::EncryptionError.invalid_key('An HMAC key is required to protect encrypted values')
          end

          # The key id is packed as an unsigned 32-bit integer, so it must be a non-negative Integer
          # that fits in four bytes.
          def validate_key_id!(key_id)
            return if key_id.is_a?(Integer) && key_id >= 0 && key_id <= 0xFFFF_FFFF

            raise Errors::EncryptionError.encryption_failed(
              "A valid key id is required to tag an encrypted value, got #{key_id.inspect}"
            )
          end

          def expect_length(bytes, length, marker)
            return bytes if bytes.bytesize == length

            raise Errors::EncryptionError
              .decryption_failed("Expected #{length} bytes for #{TypeMarker.name_for(marker)}, got #{bytes.bytesize}")
              .with_data_type(TypeMarker.name_for(marker))
          end

          def utf8(bytes)
            bytes.dup.force_encoding(Encoding::UTF_8)
          end

          # The string's text as UTF-8 bytes, which is how {deserialize_value} reads a string back. A
          # string in another encoding is converted first, so that it decrypts to the same text rather
          # than to its own bytes read as UTF-8.
          #
          # A string that cannot be converted is refused rather than stored in a form that would not
          # decrypt to what was written. The error names only the encoding, and is raised without the
          # conversion error as its cause, since that error's message quotes the character it stopped
          # at, which is part of the plaintext.
          #
          # @param string [String]
          # @return [String] binary
          # @raise [Errors::EncryptionError] if the string has no UTF-8 form
          def utf8_bytes(string)
            return string.b if string.encoding == Encoding::UTF_8
            return string.b if string.ascii_only? && string.encoding.ascii_compatible?

            converted = string.encode(Encoding::UTF_8)
            converted.b
          rescue EncodingError => e
            raise Errors::EncryptionError
              .encryption_failed("Cannot encrypt a #{string.encoding} string as UTF-8 (#{e.class})")
              .with_data_type(string.class.to_s), cause: nil
          ensure
            # The converted copy holds the plaintext too, so it is wiped along with the serialized one.
            wipe(converted)
          end

          def to_millis(value)
            (value.to_time.to_f * MILLIS_PER_SECOND).round
          end

          def from_millis(millis)
            Time.at(millis / MILLIS_PER_SECOND)
          end

          def truthy?(value)
            return value if value.is_a?(TrueClass) || value.is_a?(FalseClass)

            %w[t true y yes 1].include?(value.to_s.strip.downcase)
          end
        end
      end
    end
  end
end
