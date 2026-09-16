# IAM Authentication Plugin

The IAM Authentication Plugin enables [AWS IAM database authentication](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html) for connections made through the AWS Advanced Ruby Driver Wrapper. Instead of a static password, the plugin generates a short-lived IAM auth token and injects it into the connection properties before each connection attempt.

> [!WARNING]
> To use this plugin, you must provide valid AWS credentials. The plugin uses the AWS SDK credential provider chain. If you are using temporary credentials (STS, IAM roles, SSO), ensure they are refreshed before expiration to avoid authentication failures.
>
> For more information, see the [AWS credentials documentation](https://docs.aws.amazon.com/sdk-for-ruby/v3/developer-guide/setup-config.html).

> [!WARNING]
> It is strongly recommended to use a **TLS/SSL 1.2+ connection** with IAM database authentication. IAM auth tokens are sent as passwords and enabling SSL ensures they are encrypted in transit. Configure your driver to use SSL:
>
> **MySQL (`mysql2`):**
> ```ruby
> AwsAdvancedRubyDriverWrapper::WrapperMysql2Client.new(
>   host: "db-identifier.cluster-XYZ.us-east-2.rds.amazonaws.com",
>   username: "iam_user",
>   wrapper_plugins: "iam",
>   enable_cleartext_plugin: true,
>   sslca: "/path/to/global-bundle.pem",
>   ssl_mode: "verify_identity"
> )
> ```
>
> **PostgreSQL (`pg`):**
> ```ruby
> AwsAdvancedRubyDriverWrapper::WrapperPgConnection.new(
>   host: "db-identifier.cluster-XYZ.us-east-2.rds.amazonaws.com",
>   user: "iam_user",
>   wrapper_plugins: "iam",
>   sslmode: "verify-full",
>   sslrootcert: "/path/to/global-bundle.pem"
> )
> ```
>
> When connecting directly to an RDS or Aurora endpoint, use the AWS global certificate bundle. Download it from the [RDS SSL/TLS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).
>
> If you are connecting via a custom endpoint (e.g. a proxy or custom domain). The property `iam_host` must be set to a valid Amazon RDS endpoint and the CA certificate provided should be appropriate for that endpoint instead.

## Prerequisites

1. **Install the `aws-sdk-rds` gem.** Add it to your Gemfile:
   ```ruby
   gem 'aws-sdk-rds'
   ```

2. **Enable IAM database authentication** on your RDS or Aurora instance via the AWS Console or CLI.

3. **Create an IAM policy** granting `rds-db:connect` for the target database user. See the [IAM policy documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.IAMPolicy.html).

4. **Create a database account** mapped to IAM authentication:
   - MySQL:
     ```sql
     CREATE USER iam_user IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
     ```
   - PostgreSQL:
     ```sql
     CREATE USER iam_user;
     GRANT rds_iam TO iam_user;
     ```

## Enabling the Plugin

Add `iam` to the `wrapper_plugins` property:

```ruby
AwsAdvancedRubyDriverWrapper::WrapperMysql2Client.new(
  host: "db-identifier.cluster-XYZ.us-east-2.rds.amazonaws.com",
  username: "iam_user",
  wrapper_plugins: "failover,iam",
  enable_cleartext_plugin: true,
  sslca: "/path/to/global-bundle.pem",
  sslmode: "verify-full"
)
```

The host (or `iam_host` property if connecting to a custom domain or IP address) must be a valid Amazon RDS endpoint.

> [!IMPORTANT]
> **MySQL requires `enable_cleartext_plugin: true`.** RDS/Aurora MySQL IAM
> authentication relies on the MySQL `mysql_clear_password` client plugin, since
> the IAM auth token must be sent to the server in cleartext (the underlying
> `mysql2` driver does not enable this plugin by default). The wrapper does
> **not** set this for you, so you must pass `enable_cleartext_plugin: true` in
> your connection properties when using the IAM plugin with MySQL. Because the
> token is sent in cleartext, you must also use a TLS/SSL connection (see the
> SSL warning above) so the token is encrypted in transit.
>
> This does not apply to PostgreSQL (`pg`), which does not use the cleartext
> plugin mechanism.

## Configuration Parameters

| Parameter | Type | Required | Description | Default |
|---|---|:---:|---|---|
| `iam_host` | String | No | Overrides the hostname used to generate the IAM token. Required when connecting via a custom endpoint. | Derived from connection host |
| `iam_port` | Integer | No | Overrides the port used to generate the IAM token. | Derived from connection or dialect default |
| `iam_region` | String | No | Overrides the AWS region used to generate the IAM token. | Parsed from the RDS hostname |
| `iam_expiration` | Integer | No | Seconds before a cached IAM token is considered expired and regenerated. | `870` (14.5 min) |
| `iam_access_token_property_name` | Symbol | No | The driver property key the token is injected into. | `:password` |
| `iam_credentials_provider` | Object | No | A custom `Aws::CredentialProvider` instance. | AWS SDK default chain |

## Token Caching

The plugin caches generated tokens keyed by `region:host:port:user`. A cached token is reused until it expires (controlled by `iam_expiration`). If a login error occurs with a cached token, the plugin automatically fetches a fresh token and retries the connection once.

## Using IAM Authentication with Global Databases

When connecting to an [Amazon Aurora Global Database](https://aws.amazon.com/rds/aurora/global-database/), the IAM user or role requires the additional `rds:DescribeGlobalClusters` permission so the plugin can resolve the writer region for token generation.

Example IAM policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds-db:connect",
        "rds:DescribeGlobalClusters"
      ],
      "Resource": "*"
    }
  ]
}
```
