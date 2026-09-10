# Configuring TLS/SSL

Traffic between the AWS Advanced Ruby Driver Wrapper and your database cluster can be secured with TLS/SSL. TLS is configured with the same connection properties you would use with the underlying `mysql2` or `pg` driver directly: the wrapper passes those properties straight through to the driver. This applies to every connection the wrapper opens - including the connections it makes on your behalf for topology discovery, monitoring, and failover - because those use the same driver and the same properties. Configure SSL once in your connection properties and it applies everywhere.

## Recommendation

We strongly recommend using a **TLS 1.2+ connection with certificate verification**:

- **PostgreSQL (`pg`):** set `sslmode` to `verify-full` and provide the server CA via `sslrootcert`.
- **MySQL (`mysql2`):** set `ssl_mode` to `verify_identity` and provide the server CA via `sslca`.

`verify-full` / `verify_identity` verify both the certificate chain and that the hostname matches the certificate, which protects against man-in-the-middle attacks. Anything weaker (for example `require`, which encrypts but does not verify the server identity) leaves the connection open to impersonation.

## Not enforced by the wrapper

The wrapper **does not force TLS on, and it does not override the SSL properties you provide.** If you omit SSL configuration, the connection is made exactly as the underlying driver would make it. Enabling TLS - and choosing a verification mode - is your responsibility. We recommend the settings above, but you are free not to follow that recommendation.

Whether the *server* requires TLS is a separate, engine- and version-dependent setting that you control on the database, not in the wrapper:

- **PostgreSQL:** the `rds.force_ssl` parameter. It defaults to `1` (TLS required) on RDS for PostgreSQL 15 and later, and to `0` (optional) on version 14 and older. When it is on, non-SSL connection attempts are rejected.
- **MySQL:** the `require_secure_transport` parameter (off by default), which rejects non-SSL connections when enabled.

So depending on your engine, version, and parameter group, the server may or may not require TLS. The wrapper honors whatever you configure on both sides: it neither relaxes a server-side requirement nor imposes one of its own.

## Examples

**PostgreSQL (`pg`):**
```ruby
AwsAdvancedRubyDriverWrapper::WrapperPgConnection.new(
  host: "my-cluster.cluster-xxxx.us-east-1.rds.amazonaws.com",
  user: "<user>",
  password: "<password>",
  dbname: "mydb",
  sslmode: "verify-full",
  sslrootcert: "/path/to/global-bundle.pem"
)
```

**MySQL (`mysql2`):**
```ruby
AwsAdvancedRubyDriverWrapper::Mysql2WrapperClient.new(
  host: "my-cluster.cluster-xxxx.us-east-1.rds.amazonaws.com",
  username: "<username>",
  password: "<password>",
  database: "mydb",
  ssl_mode: "verify_identity",
  sslca: "/path/to/global-bundle.pem"
)
```

**ActiveRecord (`config/database.yml`):**
```yaml
# PostgreSQL
production:
  adapter: aws_postgresql
  host: my-cluster.cluster-xxxx.us-east-1.rds.amazonaws.com
  database: mydb
  username: admin
  password: <password>
  sslmode: verify-full
  sslrootcert: /path/to/global-bundle.pem

# MySQL
production:
  adapter: aws_mysql2
  host: my-cluster.cluster-xxxx.us-east-1.rds.amazonaws.com
  database: mydb
  username: admin
  password: <password>
  ssl_mode: verify_identity
  sslca: /path/to/global-bundle.pem
```

## Certificate bundle

When connecting to an RDS or Aurora endpoint, use the AWS global certificate bundle as the CA. Download it from the [RDS SSL/TLS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html). For driver-specific SSL options beyond those shown here, refer to the [`pg`](https://github.com/ged/ruby-pg) and [`mysql2`](https://github.com/brianmario/mysql2) driver documentation.
