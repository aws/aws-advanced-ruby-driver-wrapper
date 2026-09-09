-- MySQL functions and trigger procedure for HMAC-verified encrypted data.
-- Rejects any write to an encrypted column that was not produced by the kms_encryption plugin.
--
-- Stored payload format:
--   [ HMAC-SHA256 : 32 ][ key id : 4 ][ type marker : 1 ][ GCM IV : 12 ][ ciphertext ][ GCM tag : 16 ]
-- The HMAC covers everything after the first 32 bytes, and the HMAC key is stored (unencrypted) in
-- key_storage, so the server can verify a value's integrity tag without ever holding the data key.
--
-- Replace SCHEMA_NAME below with the schema that holds encryption_metadata and key_storage
-- (the encryption_metadata_schema property, "encrypt" by default). Requires MySQL 5.7+ / MariaDB
-- 10.2+ for SHA2().

DELIMITER $$

-- HMAC-SHA256 built from SHA2(), which MySQL has no native HMAC for.
--   HMAC(K, m) = SHA256((K' XOR opad) || SHA256((K' XOR ipad) || m))
-- All string handling is binary (X''/UNHEX/HEX) so the digest matches a standard HMAC-SHA256 for
-- keys and messages that contain high bytes.
DROP FUNCTION IF EXISTS hmac_sha256$$
CREATE FUNCTION hmac_sha256(
    message VARBINARY(65535),
    key_data VARBINARY(64)
)
RETURNS VARBINARY(32)
DETERMINISTIC
NO SQL
BEGIN
    DECLARE block_size INT DEFAULT 64;  -- SHA-256 block size
    DECLARE key_padded VARBINARY(64);
    DECLARE ipad VARBINARY(64);
    DECLARE opad VARBINARY(64);
    DECLARE i INT DEFAULT 1;
    DECLARE key_byte INT;

    -- Reduce an over-long key to its hash, then zero-pad the key to the block size.
    IF LENGTH(key_data) > block_size THEN
        SET key_padded = CONCAT(UNHEX(SHA2(key_data, 256)), REPEAT(X'00', block_size - 32));
    ELSE
        SET key_padded = CONCAT(key_data, REPEAT(X'00', block_size - LENGTH(key_data)));
    END IF;

    -- ipad = key XOR 0x36 per byte, opad = key XOR 0x5C per byte, one raw byte at a time.
    SET ipad = X'';
    SET opad = X'';
    WHILE i <= block_size DO
        SET key_byte = ASCII(SUBSTRING(key_padded, i, 1));
        SET ipad = CONCAT(ipad, UNHEX(LPAD(HEX(key_byte ^ 0x36), 2, '0')));
        SET opad = CONCAT(opad, UNHEX(LPAD(HEX(key_byte ^ 0x5C), 2, '0')));
        SET i = i + 1;
    END WHILE;

    RETURN UNHEX(SHA2(CONCAT(opad, UNHEX(SHA2(CONCAT(ipad, message), 256))), 256));
END$$

-- Verifies that a stored value carries a valid HMAC for the given HMAC key.
DROP FUNCTION IF EXISTS verify_encrypted_data_hmac$$
CREATE FUNCTION verify_encrypted_data_hmac(
    data VARBINARY(65535),
    hmac_key VARBINARY(32)
)
RETURNS BOOLEAN
DETERMINISTIC
NO SQL
BEGIN
    -- Minimum payload: 32 (HMAC) + 4 (key id) + 1 (type) + 12 (IV) + 0 (ciphertext) + 16 (GCM tag) = 65.
    IF data IS NULL OR LENGTH(data) < 65 THEN
        RETURN FALSE;
    END IF;

    RETURN SUBSTRING(data, 1, 32) = hmac_sha256(SUBSTRING(data, 33), hmac_key);
END$$

-- Called from a BEFORE INSERT / BEFORE UPDATE trigger to reject a value that is not a valid
-- kms_encryption payload. Reads the column's HMAC key from key_storage; it uses no dynamic SQL, so
-- it is safe to invoke from a trigger.
DROP PROCEDURE IF EXISTS validate_encrypted_data_hmac_before_insert$$
CREATE PROCEDURE validate_encrypted_data_hmac_before_insert(
    IN p_table_name VARCHAR(64),
    IN p_column_name VARCHAR(64),
    IN column_value VARBINARY(65535)
)
BEGIN
    DECLARE v_hmac_key VARBINARY(32);

    IF column_value IS NOT NULL THEN
        SELECT ks.hmac_key INTO v_hmac_key
        FROM SCHEMA_NAME.encryption_metadata em
        JOIN SCHEMA_NAME.key_storage ks ON em.key_id = ks.id
        WHERE em.table_name = p_table_name
          AND em.column_name = p_column_name
        LIMIT 1;

        IF v_hmac_key IS NULL THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No HMAC key is configured for the encrypted column';
        END IF;

        IF NOT verify_encrypted_data_hmac(column_value, v_hmac_key) THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Column does not carry a valid HMAC tag (plaintext or tampered value)';
        END IF;
    END IF;
END$$

DELIMITER ;

-- Add one pair of triggers per encrypted column, for example on users.ssn:
--
-- DELIMITER $$
-- CREATE TRIGGER users_ssn_hmac_check
-- BEFORE INSERT ON users
-- FOR EACH ROW
-- BEGIN
--     CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn);
-- END$$
--
-- CREATE TRIGGER users_ssn_hmac_check_update
-- BEFORE UPDATE ON users
-- FOR EACH ROW
-- BEGIN
--     CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn);
-- END$$
-- DELIMITER ;
