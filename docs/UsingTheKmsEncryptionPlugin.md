# KMS Encryption Plugin

The KMS Encryption Plugin encrypts individual table columns with data keys held in [AWS KMS](https://aws.amazon.com/kms/), without the application having to know about it. Which columns are encrypted is configured in the database rather than in application code, so it can change without redeploying the application. That configuration is managed through `Plugins::Encryption::KeyManagementUtility`, which records the column and stores its data key together; editing the `encryption_metadata` and `key_storage` tables by hand is not recommended, since a column is only usable once a matching data key exists in `key_storage`. When a statement writes to one of those columns the plugin encrypts the bind parameter on its way to the server, and when a statement reads one back it decrypts the value on its way to the application. The plaintext never reaches the server, and neither does any data key: only a KMS-encrypted copy of each data key is stored, in `key_storage`.

> [!IMPORTANT]
> On its own, the plugin cannot guarantee that an encrypted column never holds a plaintext value:
> - the plugin only sees the statements this wrapper sends over a connection that has the plugin enabled
> - the plugin identifies which columns to encrypt by parsing each statement's SQL, and this parsing is best-effort: for complex SQL it may fail to recognize that a statement writes an encrypted column, in which case the plugin cannot encrypt it
>
> To guarantee that plaintext values are never written to an encrypted column, server-side encryption enforcement in the database is required - the database-side triggers, not the SQL parser, are what guarantee an encrypted column never holds plaintext. The plugin can technically be included in your plugin list without server side encryption enforcement, but that enforcement is the only way to ensure with 100% certainty that an encrypted column never holds plaintext. See [enforce encryption in the database](#enforce-encryption-in-the-database) to set up server-side enforcement. Read [paths that are not covered](#paths-that-are-not-covered) as well before relying on the plugin.

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

| Parameter | Type | Required | Description | Example                               | Default |
|---|---|:---:|---|---------------------------------------|---|
| `encryption_metadata_schema` | String | No | Schema holding the `encryption_metadata` and `key_storage` tables. | `'app_encrypt'`                       | `'encrypt'` |
| `encryption_kms_region` | String | Yes | AWS region for KMS calls. Falls back to the `AWS_REGION` or `AWS_DEFAULT_REGION` environment variable; the plugin raises if none of these is set. | `'us-east-2'`                         | None |
| `encryption_kms_endpoint` | String | No | Endpoint URL override for KMS. | `'http://localhost:4566'`             | `nil` |
| `aws_credentials_provider` | `Aws::CredentialProvider` | No | A custom AWS credentials provider instance for authenticating with KMS. | `Aws::AssumeRoleCredentials.new(...)` | AWS SDK default chain |
| `encryption_metadata_cache_enabled` | Boolean | No | Cache the encryption metadata in memory. Leave it enabled in production: when disabled, the plugin opens a short-lived metadata connection for **every** statement that touches an encrypted column. If you need fresher metadata, lower `encryption_metadata_cache_refresh_interval_sec` rather than disabling the cache. | `true`                                | `true` |
| `encryption_metadata_cache_expiration_sec` | Float | No | How long cached encryption metadata stays valid, in seconds. | `600.0`                                 | `3600.0` |
| `encryption_metadata_cache_refresh_interval_sec` | Float | No | How often the encryption metadata is refreshed in the background, in seconds. Set to `0` to disable background refresh. | `60.0`                                  | `300.0` |
| `encryption_data_key_cache_enabled` | Boolean | No | Cache decrypted data keys in memory. Leave it enabled in production: when disabled, the plugin makes a KMS `Decrypt` call for **every** statement that touches an encrypted column, which adds latency and cost and can hit KMS request-rate limits. Disabling it does shorten how long a plaintext data key stays in memory, so treat it as a deliberate throughput-versus-key-exposure tradeoff rather than an off-by-default setting. | `true`                                | `true` |
| `encryption_data_key_cache_max_size` | Integer | No | Maximum number of decrypted data keys held in memory. | `100`                                 | `1000` |
| `encryption_data_key_cache_expiration_sec` | Float | No | How long a decrypted data key stays cached, in seconds. | `600.0`                                 | `300.0` |
| `encryption_key_management_max_retries` | Integer | No | Maximum number of retries for throttled or failed KMS calls. | `5`                                   | `3` |
| `encryption_key_management_retry_backoff_base_sec` | Float | No | Base delay in seconds for the exponential backoff between KMS retries. | `0.25`                                 | `0.1` |
| `encryption_audit_logging_enabled` | Boolean | No | Log an audit record for every key management, encryption, and decryption operation. | `true`                                | `false` |
| `encryption_return_unverified_data` | Boolean | No | **Do not enable in production.** On read, return a value as it is stored when it cannot be confirmed to be this column's encrypted data (too short to be a payload, or a failed HMAC) instead of raising. Intended only for reading data written before the column was encrypted. A value that verifies but cannot be decrypted (a wrong data key) still raises. See [Reading data written before encryption](#reading-data-written-before-encryption). | `false`                               | `false` |

## Paths that are covered

Encryption applies to **bind parameters**, so a value can be encrypted only when it is bound rather than written into the SQL text:

```ruby
# pg
conn.exec_params('INSERT INTO users (name, ssn) VALUES ($1, $2)', ['Jo', '123-45-6789'])
conn.exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).each { |row| row['ssn'] }

# mysql2
client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)').execute('Jo', '123-45-6789')
```

> [!IMPORTANT]
> **On MySQL with ActiveRecord, set `prepared_statements: true` on the connection.** The `aws_mysql2` adapter (like the underlying `mysql2` adapter) defaults prepared statements **off**, and with them off ActiveRecord writes a value into the SQL text as a literal rather than binding it. The plugin cannot encrypt a literal, so a write to an encrypted column is refused (`Errors::MetadataError`, see [below](#refused-so-the-plaintext-is-not-stored)). Enable them in `database.yml` so values are bound and can be encrypted:
> ```yaml
> production:
>   adapter: aws_mysql2
>   prepared_statements: true
>   # ...
> ```
> The `aws_postgresql` adapter already defaults prepared statements on, so PostgreSQL needs no change.
>
> Prepared statements are off by default on the mysql2 adapter for a reason, so weigh the trade-off before enabling them fleet-wide:
> - **Connection poolers/proxies.** Server-side prepared statements are bound to a specific backend connection. A pooler that multiplexes many clients onto fewer backends — Amazon RDS Proxy, ProxySQL, PgBouncer in transaction mode — may be unable to reuse them, which forces session pinning (defeating much of the pooling benefit) or surfaces `Unknown prepared statement handler` errors.
> - **Server statement limits.** Each prepared statement consumes a handle against MySQL's `max_prepared_stmt_count`; many long-lived pooled connections each preparing many distinct statements can exhaust it and start failing with `Can't create more than max_prepared_stmt_count statements`.
>
> If you cannot enable prepared statements, the plugin still cannot encrypt an inlined literal — scope the encrypted columns to writes you can issue as bound parameters (a raw prepared/`exec_params` statement, or an `/*@encrypt:table.column*/` annotation on a bound value), and rely on the required [server-side trigger](#enforce-encryption-in-the-database) to reject any plaintext that slips through.

- Bind parameters of an `INSERT`, `UPDATE`, or `REPLACE` whose columns the plugin can read from the statement, including a multi-row `VALUES` list and the assignments of an upsert (`ON CONFLICT ... DO UPDATE` on PostgreSQL, `ON DUPLICATE KEY UPDATE` on MySQL). On PostgreSQL this also covers a `MERGE`'s `WHEN MATCHED ... UPDATE` / `WHEN NOT MATCHED ... INSERT` clauses and a data-modifying common table expression, for example `WITH w AS (INSERT INTO users (ssn) VALUES ($1) RETURNING id) SELECT * FROM w`.
- Bind parameters compared against an encrypted column in a `WHERE` clause. Note that encryption is randomized, with a fresh IV per value, so the ciphertext differs every time and an equality search against an encrypted column will not match anything — it silently returns no rows rather than matching, and nothing leaks through deterministic ciphertext. In an ActiveRecord app the same applies to finders and validations that compare an encrypted column: `where(ssn: x)`, `find_by(ssn: x)`, and `validates_uniqueness_of :ssn` never match an existing row, so a uniqueness validation silently passes even when a duplicate exists. Filter, look up, and enforce uniqueness on a column that is not encrypted instead.
- Statements run by name after being prepared, whether prepared by the driver's own `prepare` or by a `PREPARE` sent as a statement. A `PREPARE` is also checked as it is sent, so a plaintext written into the statement it carries is caught at that point.
- Reads, however the rows come back. A row read as a hash is matched to its columns by name; a row read as a **bare array** of values is matched by position, using the column names the result reports — which is what lets **ActiveRecord** reads decrypt even though it fetches rows as arrays (mysql2 in `as: :array` mode, `PG::Result#values`). This covers `PG::Result#each`, `#each_row`, `#to_a`, `#[]`, `#values`, `#field_values`, `#column_values`, `#tuple`, `#tuple_values` and `#getvalue`, its single-row-mode `#stream_each`/`#stream_each_row`/`#stream_each_tuple`, and mysql2's hash and array results alike. A decrypted value is always returned as a **string**, whatever type it had when it was written: an encrypted column is a binary column (`bytea` or `VARBINARY`), and a string keeps the read consistent with the column's real type and with how ActiveRecord treats it. Cast the value on read when you need another type, for example `row['age'].to_i`. The one exception is `COPY ... TO`, whose rows are a stream rather than values the plugin can replace, so it hands back the stored payload as-is.
- A column named explicitly with an annotation, which takes precedence over anything the parser found. This is the escape hatch for a statement the plugin cannot read:
  ```ruby
  conn.exec_params('INSERT INTO users (name, ssn) VALUES ($1, /*@encrypt:users.ssn*/ $2)', ...)
  ```

The plugin treats reads and writes differently. A **read fails closed**: a value read from an encrypted column that does not verify - it is not a valid encrypted payload, or its integrity tag does not match - is refused with an `Errors::EncryptionError` rather than handed back, so the application never receives a value the wrapper cannot vouch for. A consequence worth noting: a value that reached an encrypted column outside the plugin, including data that predates the column being encrypted, will raise when read back through the plugin, so encrypt existing data before it is read through an encrypted column (or, only for a controlled migration, see [Reading data written before encryption](#reading-data-written-before-encryption)). A **write** is the opposite - when the plugin cannot do its job it mostly stays out of the way and leaves the value to the [server-side enforcement](#enforce-encryption-in-the-database), which is what actually guarantees an encrypted column never holds a plaintext, with one exception: it **fails closed** and raises `Errors::MetadataError` when it can confirm a column is encrypted and sees the statement writing it with something other than a bind parameter, which cannot be encrypted and is almost always a mistake. Everything else on a write it cannot fully read, it passes through - see [Paths that are not covered](#paths-that-are-not-covered).

### Reading data written before encryption

When you enable encryption on a column that already holds plaintext, those existing rows are not encrypted payloads, so reading them back through the plugin fails closed and raises. The supported way to handle this is to **encrypt the existing data** (read each value and write it back through the plugin so it is stored encrypted) before the application reads the column normally.

For a controlled migration where that is not yet possible, `encryption_return_unverified_data` (default `false`) makes the read **lenient**: a value that cannot be confirmed to be this column's encrypted data - too short to be a payload, or a failed HMAC - is returned exactly as the database holds it instead of raising, so legacy plaintext reads back untouched while genuinely encrypted values still decrypt.

> [!WARNING]
> **Do not enable `encryption_return_unverified_data` in production.** It lets unverified data reach the application and removes the read path's tamper detection: a value that fails its integrity check can no longer be told apart from a value that was never encrypted, so a tampered or corrupted value is returned silently. Use it only for a bounded migration of pre-existing data, then turn it off. Even when it is enabled, a value that verifies but cannot be decrypted (a wrong or mismatched data key) still raises, because that indicates a real key fault rather than legacy plaintext.

## Paths that are not covered

Only the required [server-side enforcement](#enforce-encryption-in-the-database) guarantees an encrypted column never holds a plaintext. The plugin encrypts what it can confidently identify and, apart from the one refusal below, leaves everything else to that enforcement rather than refusing statements it cannot fully read - which would reject legitimate statements that never touch an encrypted column.

### Refused, so the plaintext is not stored

A write **raises `Errors::MetadataError`** in one case: the plugin can confirm a column is encrypted, but the statement writes it with something other than a bind parameter - a value in the SQL text, an expression around a parameter, a `DEFAULT`, or a `COPY ... FROM` that names the column. None of these can be encrypted, and it is almost always a mistake, so the write is refused with advice to bind the value (or, for a `COPY`, use `INSERT`). An annotation naming the column overrides this wherever there is a parameter for it to name, which a `COPY` does not have.

### Passed through, relying on the database

When the plugin can see a statement writes but cannot establish which columns - so it cannot be sure an encrypted column is even involved - it lets the statement through and leaves any plaintext for the database to reject, rather than refusing a statement that may touch no encrypted column at all. This covers an `INSERT` that does not name its columns, an `INSERT` whose values come from a nested `SELECT`, an `UPDATE` naming more than one table (which of them an assignment belongs to cannot be established), a `MERGE` clause or data-modifying CTE whose written columns cannot be enumerated, a `COPY ... FROM` that names no columns, a statement prepared somewhere the connection could not read, a write the parser could not read at all, and any statement while the plugin's own metadata tables are unreadable. It is logged - at `warn` when the target table is known to have encrypted columns, at `debug` otherwise.

### Not seen at all, so a plaintext is stored silently

> [!WARNING]
> On the paths below the plugin never sees the write at all, so a plaintext goes to the server and is stored, with nothing raised and nothing logged at write time. The server-side HMAC-validation trigger (see [Enforce encryption in the database](#enforce-encryption-in-the-database)) is what stops these paths from storing a plaintext. Without the trigger the plaintext is stored; a later read of it through the plugin fails closed and raises, but a read that does not go through the plugin still returns it in the clear.

- `LOAD DATA INFILE` on MySQL, and a `COPY ... FROM` whose statement text cannot be parsed.
- Anything the server runs on the application's behalf: `CALL`, `DO`, a function, a stored routine, a trigger.
- MySQL's `PREPARE stmt FROM '<statement text>'` together with `EXECUTE stmt USING @vars`, and SQL-level `EXECUTE` with inline literals: the values live in server-side variables the plugin never sees.
- The second and later statements of a multi-statement string.
- Everything that reaches the column without passing through a connection that has the plugin enabled: `psql` or the `mysql` client, a migration tool, another service, a wrapper connection whose `wrapper_plugins` does not include `kms_encryption`, and whatever was already in the table before the column was configured.

## Enforce encryption in the database

> [!WARNING]
> **A database-side HMAC-validation trigger is required on every encrypted column to prevent plaintext writes — install the one below for each.** Without it, the checks in this plugin are the only thing standing between a plaintext and an encrypted column, and they cover only the statements this wrapper sends over a connection with the plugin enabled. A plaintext that gets past them is stored: a later read through the plugin fails closed and raises rather than returning it, but a read that bypasses the plugin still returns it in the clear, and the trigger is the only thing that keeps it out of the column in the first place. Whether the column holds only ciphertext is a property of the database, and only the database can enforce it.

The trigger needs no help from the application, because the HMAC key that signs each value is stored unencrypted in `key_storage`: the server can verify that a value carries a valid integrity tag without ever holding the data key, and so without being able to decrypt anything.

### PostgreSQL

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Refuses any value that does not carry a valid HMAC tag for this column: a plaintext,
-- or a value that was tampered with or written under a different key.
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

  -- Payload: [ HMAC-SHA256 tag : 32 ][ key id : 4 ][ type marker : 1 ][ GCM IV : 12 ][ ciphertext ][ GCM tag : 16 ]
  IF length(col_value) < 65
     OR substring(col_value from 1 for 32) <> hmac(substring(col_value from 33), hmac_key, 'sha256') THEN
    RAISE EXCEPTION 'Column %.% does not carry a valid HMAC tag (plaintext or tampered value)', TG_TABLE_NAME, col_name;
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

MySQL has no built-in HMAC function, so the equivalent builds HMAC-SHA256 out of `SHA2()`. The functions and trigger procedure are in [`spec/integration/host/src/test/resources/sql/encrypted_data_type_mysql.sql`](../spec/integration/host/src/test/resources/sql/encrypted_data_type_mysql.sql). Replace `SCHEMA_NAME` in that file with the value of `encryption_metadata_schema`, then run it to create the `hmac_sha256` and `verify_encrypted_data_hmac` functions and the `validate_encrypted_data_hmac_before_insert` procedure. On Aurora/RDS MySQL, creating the functions may require the cluster parameter `log_bin_trust_function_creators` to be set to `1`.

Add a `BEFORE INSERT` and a `BEFORE UPDATE` trigger per encrypted column, each calling the procedure so a value that is not a valid payload raises `SIGNAL SQLSTATE '45000'`:

```sql
CREATE TRIGGER users_ssn_encrypted_insert
BEFORE INSERT ON users
FOR EACH ROW
CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn);

CREATE TRIGGER users_ssn_encrypted_update
BEFORE UPDATE ON users
FOR EACH ROW
CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn);
```

## Hardening the deployment

Two access-control boundaries do most of the work of keeping the encryption meaningful: which KMS keys the application can reach, and who can write the metadata schema.

### Restrict the KMS keys the application can use

Grant the credentials the plugin runs under only the KMS actions they need, scoped to the specific master key ARN(s) recorded in `key_storage` — never `Resource: "*"`. Use a distinct key per environment.

At runtime the plugin only decrypts stored data keys, so the application's role needs just `kms:Decrypt` on those keys:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    }
  ]
}
```

The administrative side (`KeyManagementUtility`: creating master keys, turning encryption on for a column, rotating data keys) additionally calls `kms:GenerateDataKey`, `kms:CreateKey`, `kms:CreateAlias`, and `kms:DescribeKey`. Run it under a separate, admin-only credential rather than granting those actions to the application's runtime role.

### Restrict write access to the metadata schema

`encryption_metadata` records which columns are encrypted, and `key_storage` holds each column's KMS-encrypted data key alongside its HMAC key (in the clear). Anyone who can **write** those tables can defeat the protection: substituting a known HMAC key lets them forge values that pass the server-side trigger, and repointing a column at a key they control lets them read or replace its data. Whether the column holds only ciphertext is only as strong as who can change `key_storage`.

At runtime the plugin only reads the metadata schema, so grant the application's database role `SELECT` on it and nothing more. Reserve `INSERT`/`UPDATE`/`DELETE` for the administrative role that runs `KeyManagementUtility`.

```sql
-- PostgreSQL
GRANT USAGE ON SCHEMA encrypt TO app_role;
GRANT SELECT ON ALL TABLES IN SCHEMA encrypt TO app_role;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA encrypt FROM app_role;
```

```sql
-- MySQL (the encrypt schema is a database)
GRANT SELECT ON encrypt.* TO 'app_user'@'%';
-- grant INSERT/UPDATE/DELETE on encrypt.* only to the administrative user
```

The application's role does still need `SELECT` on `key_storage`, both to read key material and because the server-side trigger reads the HMAC key as the invoking user.
