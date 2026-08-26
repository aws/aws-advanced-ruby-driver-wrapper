# KMS Encryption Plugin

The KMS Encryption Plugin encrypts individual table columns with data keys held in [AWS KMS](https://aws.amazon.com/kms/), without the application having to know about it. Which columns are encrypted is configured in the database itself, in the `encryption_metadata` table, so it can be changed without redeploying the application. When a statement writes to one of those columns the plugin encrypts the bind parameter on its way to the server, and when a statement reads one back it decrypts the value on its way to the application. The plaintext never reaches the server, and neither does any data key: only a KMS-encrypted copy of each data key is stored, in `key_storage`.

> [!IMPORTANT]
> The plugin only sees the statements this wrapper sends, so it cannot guarantee that an encrypted column never holds a plaintext. Read [Paths that are not covered](#paths-that-are-not-covered) and [Enforce encryption in the database](#enforce-encryption-in-the-database) before relying on it.

## Enabling the Plugin

> [!WARNING]
> To use this plugin, you must add `aws-sdk-kms` to your Gemfile:
> ```ruby
> gem 'aws-sdk-kms'
> ```

> [!WARNING]
> To use this plugin, you must provide valid AWS credentials. The AWS SDK relies on the AWS SDK credential provider chain to authenticate with AWS services. If you are using temporary credentials (such as those obtained through AWS STS, IAM roles, or SSO), be aware that these credentials have an expiration time. AWS SDK exceptions will occur and the plugin will not work properly if your credentials expire without being refreshed or replaced.

To enable the KMS Encryption Plugin, add the plugin code `kms_encryption` to the `wrapper_plugins` connection property.

The plugin expects two tables in the schema named by `encryption_metadata_schema`: `encryption_metadata`, which records the encrypted columns, and `key_storage`, which holds each KMS-encrypted data key alongside the HMAC key that signs its values. Every encrypted column must be a binary column (`bytea` on PostgreSQL, `VARBINARY` or `BLOB` on MySQL), since what is stored is a binary payload rather than the original value. `Plugins::Encryption::KeyManagementUtility` is the administrative side of the plugin: it creates master keys, turns encryption on or off for a column, and rotates data keys. None of it runs during normal query execution.

## Parameters

| Parameter | Type | Required | Description | Example | Default |
|---|---|:---:|---|---|---|
| `encryption_metadata_schema` | String | No | Schema holding the `encryption_metadata` and `key_storage` tables. | `'app_encrypt'` | `'encrypt'` |
| `encryption_kms_region` | String | Yes | AWS region for KMS calls. Falls back to the `AWS_REGION` or `AWS_DEFAULT_REGION` environment variable; the plugin raises if none of these is set. | `'us-east-2'` | None |
| `encryption_kms_endpoint` | String | No | Endpoint URL override for KMS. | `'http://localhost:4566'` | `nil` |
| `aws_credentials_provider` | `Aws::CredentialProvider` | No | A custom AWS credentials provider instance for authenticating with KMS. | `Aws::AssumeRoleCredentials.new(...)` | AWS SDK default chain |
| `encryption_metadata_cache_enabled` | Boolean | No | Cache the encryption metadata in memory instead of querying it per statement. | `false` | `true` |
| `encryption_metadata_cache_expiration_sec` | Integer | No | How long cached encryption metadata stays valid, in seconds. | `600` | `3600` |
| `encryption_metadata_cache_refresh_interval_sec` | Integer | No | How often the encryption metadata is refreshed in the background, in seconds. Set to `0` to disable background refresh. | `60` | `300` |
| `encryption_data_key_cache_enabled` | Boolean | No | Cache decrypted data keys in memory to avoid a KMS `Decrypt` call per statement. | `false` | `true` |
| `encryption_data_key_cache_max_size` | Integer | No | Maximum number of decrypted data keys held in memory. | `100` | `1000` |
| `encryption_data_key_cache_expiration_sec` | Integer | No | How long a decrypted data key stays cached, in seconds. | `600` | `3600` |
| `encryption_key_management_max_retries` | Integer | No | Maximum number of retries for throttled or failed KMS calls. | `5` | `3` |
| `encryption_key_management_retry_backoff_base_ms` | Integer | No | Base delay in milliseconds for the exponential backoff between KMS retries. | `250` | `100` |
| `encryption_audit_logging_enabled` | Boolean | No | Log an audit record for every key management, encryption, and decryption operation. | `true` | `false` |

## Paths that are covered

Encryption applies to **bind parameters**, so a value can be encrypted only when it is bound rather than written into the SQL text:

```ruby
# pg
conn.exec_params('INSERT INTO users (name, ssn) VALUES ($1, $2)', ['Jo', '123-45-6789'])
conn.exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).each { |row| row['ssn'] }

# mysql2
client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)').execute('Jo', '123-45-6789')
```

- Bind parameters of an `INSERT`, `UPDATE`, or `REPLACE` whose columns the plugin can read from the statement, including a multi-row `VALUES` list and the assignments of an upsert (`ON CONFLICT ... DO UPDATE` on PostgreSQL, `ON DUPLICATE KEY UPDATE` on MySQL). On PostgreSQL this also covers a `MERGE`'s `WHEN MATCHED ... UPDATE` / `WHEN NOT MATCHED ... INSERT` clauses and a data-modifying common table expression, for example `WITH w AS (INSERT INTO users (ssn) VALUES ($1) RETURNING id) SELECT * FROM w`.
- Bind parameters compared against an encrypted column in a `WHERE` clause. Note that encryption is randomized, with a fresh IV per value, so the ciphertext differs every time and an equality search against an encrypted column will not match anything. Filter on a column that is not encrypted instead.
- Statements run by name after being prepared, whether prepared by the driver's own `prepare` or by a `PREPARE` sent as a statement. A `PREPARE` is also checked as it is sent, so a plaintext written into the statement it carries is caught at that point.
- Reads that return rows as hashes or single values: `PG::Result#each`, `#to_a`, `#[]` and `#field_values`, and mysql2's default hash and array-of-hash results. A decrypted value is always returned as a **string**, whatever type it had when it was written: an encrypted column is a binary column (`bytea` or `VARBINARY`), and a string keeps the read consistent with the column's real type and with how ActiveRecord treats it. Cast the value on read when you need another type, for example `row['age'].to_i`. The exception is reads that return rows as **bare arrays** — `PG::Result#each_row`, `#values`, `#column_values` and `#tuple`, mysql2's `as: :array` option, and `COPY ... TO` — which give the plugin no column names to match against the configuration, so they are **not** decrypted and hand back the stored payload as-is; read those columns through one of the hash-returning methods above.
- A column named explicitly with an annotation, which takes precedence over anything the parser found. This is the escape hatch for a statement the plugin cannot read:
  ```ruby
  conn.exec_params('INSERT INTO users (name, ssn) VALUES ($1, /*@encrypt:users.ssn*/ $2)', ...)
  ```

A read and a write behave differently when the plugin cannot do its job. A read is **lenient**: a value whose integrity check does not pass is handed to the application exactly as the database holds it, which is what the application would have got without the plugin. A write **fails closed** and raises `Errors::MetadataError`, because leaving the column alone there means storing a plaintext in a column configured to be encrypted.

## Paths that are not covered

### Refused, so the plaintext is not stored

A write raises rather than storing a value the plugin cannot encrypt. This covers a value written into the SQL text, an expression around a parameter, a `DEFAULT`, a nested `SELECT`, an `INSERT` that does not name its columns, a `COPY ... FROM`, an `UPDATE` naming more than one table (which of them an assignment belongs to cannot be established), and a statement prepared somewhere the connection could not read. The same applies inside a `MERGE` clause or a data-modifying CTE: when its written columns cannot be enumerated the whole statement is refused. An annotation overrides this wherever there is a parameter for it to name, which a `COPY` does not have.

### Not seen at all, so a plaintext is stored silently

> [!WARNING]
> On the paths below the plugin cannot tell that an encrypted column is being written, so a plaintext goes to the server, is stored as-is, and reads back as-is forever after, since the read path only decrypts a value whose integrity tag verifies. Nothing raises and nothing is logged.

- `LOAD DATA INFILE` on MySQL, and a `COPY ... FROM` whose statement text cannot be parsed.
- Anything the server runs on the application's behalf: `CALL`, `DO`, a function, a stored routine, a trigger.
- MySQL's `PREPARE stmt FROM '<statement text>'` together with `EXECUTE stmt USING @vars`, and SQL-level `EXECUTE` with inline literals: the values live in server-side variables the plugin never sees.
- The second and later statements of a multi-statement string.
- Everything that reaches the column without passing through this wrapper: `psql` or the `mysql` client, a migration tool, another service, and whatever was already in the table before the column was configured.

## Enforce encryption in the database

> [!WARNING]
> **Install the trigger below for every encrypted column.** Without it, the checks in this plugin are the only thing standing between a plaintext and an encrypted column, and they cover only the statements this wrapper sends. A plaintext that gets past them is stored silently, reads back silently, and is indistinguishable from a legitimately unencrypted legacy value: there is no error, no log line, and no way to tell afterwards how long the value sat in the clear. Whether the column holds only ciphertext is a property of the database, and only the database can enforce it.

The trigger needs no help from the application, because the HMAC key that signs each value is stored unencrypted in `key_storage`: the server can verify that a value carries a valid integrity tag without ever holding the data key, and so without being able to decrypt anything.

### PostgreSQL

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Refuses any value that was not written by the kms_encryption plugin.
-- Replace 'encrypt' below if encryption_metadata_schema is set to something else.
CREATE OR REPLACE FUNCTION enforce_encrypted_column() RETURNS trigger AS $$
DECLARE
  col_name  text := TG_ARGV[0];
  col_value bytea;
  hmac_key  bytea;
  cache_key text := 'hmac_key.' || TG_TABLE_NAME || '.' || col_name;
BEGIN
  EXECUTE format('SELECT ($1).%I', col_name) INTO col_value USING NEW;
  IF col_value IS NULL THEN
    RETURN NEW;
  END IF;

  BEGIN
    hmac_key := decode(current_setting(cache_key), 'hex');
  EXCEPTION WHEN OTHERS THEN
    SELECT ks.hmac_key INTO hmac_key
      FROM encrypt.encryption_metadata em
      JOIN encrypt.key_storage ks ON em.key_id = ks.id
     WHERE em.table_name = TG_TABLE_NAME AND em.column_name = col_name;

    IF hmac_key IS NULL THEN
      RAISE EXCEPTION 'No HMAC key is configured for %.%', TG_TABLE_NAME, col_name;
    END IF;

    PERFORM set_config(cache_key, encode(hmac_key, 'hex'), true);
  END;

  -- Payload: [ HMAC-SHA256 tag : 32 ][ type marker : 1 ][ GCM IV : 12 ][ ciphertext ][ GCM tag : 16 ]
  IF length(col_value) < 61
     OR substring(col_value from 1 for 32) <> hmac(substring(col_value from 33), hmac_key, 'sha256') THEN
    RAISE EXCEPTION 'Column %.% was not written by the kms_encryption plugin', TG_TABLE_NAME, col_name;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Add one trigger per encrypted column:

```sql
CREATE TRIGGER users_ssn_encrypted
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION enforce_encrypted_column('ssn');
```

The HMAC key is cached for the length of the transaction rather than the session, so that a key rotation takes effect immediately. Widen it to the session with `set_config(..., false)` if the per-transaction metadata lookup costs more than the rotation delay is worth.

### MySQL

MySQL has no built-in HMAC function, so the equivalent builds HMAC-SHA256 out of `SHA2()`. A working version, along with the PostgreSQL functions above in the form the integration tests use them, is in [`spec/integration/host/src/test/resources/sql/`](../spec/integration/host/src/test/resources/sql/). Install its `hmac_sha256` and `verify_encrypted_data_hmac` functions and the `validate_encrypted_data_hmac_before_insert` procedure, then add a `BEFORE INSERT` and a `BEFORE UPDATE` trigger per encrypted column, each calling the procedure so a value that fails the check raises `SIGNAL SQLSTATE '45000'`.
