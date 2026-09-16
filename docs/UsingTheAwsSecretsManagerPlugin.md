# AWS Secrets Manager Plugin

The AWS Advanced Ruby Driver Wrapper supports usage of database credentials stored as secrets in [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/) through the Secrets Manager Plugin. When you create a new connection with this plugin enabled, the plugin will retrieve the secret and the connection will be created with the credentials inside that secret.

## Enabling the Plugin

> [!WARNING]
> To use this plugin, you must add `aws-sdk-secretsmanager` to your Gemfile:
> ```ruby
> gem 'aws-sdk-secretsmanager'
> ```

> [!WARNING]
> To use this plugin, you must provide valid AWS credentials. The AWS SDK relies on the AWS SDK credential provider chain to authenticate with AWS services. If you are using temporary credentials (such as those obtained through AWS STS, IAM roles, or SSO), be aware that these credentials have an expiration time. AWS SDK exceptions will occur and the plugin will not work properly if your credentials expire without being refreshed or replaced. To avoid interruptions:
> - Ensure your credential provider supports automatic refresh (most AWS SDK credential providers do this automatically)
> - Monitor credential expiration times in production environments
> - Configure appropriate session durations for temporary credentials
> - Implement proper error handling for credential-related failures

To enable the Secrets Manager Plugin, add the plugin code `secrets_manager` to the `wrapper_plugins` connection property.

## Parameters

The following properties are required for the Secrets Manager Plugin to retrieve database credentials from AWS Secrets Manager.

| Parameter | Type | Required | Description | Example | Default |
|---|---|:---:|---|---|---|
| `secret_id` | String | Yes | The name or ARN of the secret to retrieve. | `'my-db-secret'` | `nil` |
| `secret_region` | String | Yes, unless `secret_id` is an ARN | The AWS region your secret is in. If `secret_id` is an ARN, the region is parsed from it automatically. | `'us-east-2'` | `nil` |
| `secret_endpoint` | String | No | Endpoint URL override for Secrets Manager. Must include a valid protocol (e.g. `http://`) and domain. A port number is not required. | `'http://localhost:1234'` | `nil` |
| `secret_expiration_sec` | Float | No | Time in seconds that secrets are cached before being re-fetched. Minimum value is `300`. | `600.0` | `870.0` |
| `secret_username_key` | String | No | The key in the JSON secret that contains the username for the database connection. | `'writerUsername'` | `'username'` |
| `secret_password_key` | String | No | The key in the JSON secret that contains the password for the database connection. | `'readerPassword'` | `'password'` |
| `secret_credentials_provider` | `Aws::CredentialProvider` | No | A custom AWS credentials provider instance for authenticating with Secrets Manager. | `Aws::AssumeRoleCredentials.new(...)` | AWS SDK default chain |
| `secret_rotation_retry_timeout_sec` | Float | No | Maximum time in seconds to retry connecting during a secret rotation window. Set to `0` to disable. | `30.0` | `0.0` |
| `secret_rotation_retry_base_delay_sec` | Float | No | Base delay in seconds for exponential backoff during rotation retry. | `1.0` | `0.5` |

*Note:* A Secret ARN has the format: `arn:aws:secretsmanager:<Region>:<AccountId>:secret:SecretName-6RandomCharacters`

## Secret Data

The secret stored in AWS Secrets Manager should be a JSON object containing the `username` and `password` keys. If the secret contains different key names, you can specify them with the `secret_username_key` and `secret_password_key` parameters.

## Secret Rotation

AWS Secrets Manager does not require credential rotation, and the wrapper does not enforce it. However, we recommend enabling [automatic rotation](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html) for your database secret so that credentials are changed on a regular schedule and a leaked secret has a bounded lifetime.

The plugin is designed to keep working across a rotation:

- Fetched credentials are cached for `secret_expiration_sec` (default `870`), then re-fetched from Secrets Manager, so a rotated secret is picked up automatically once the cache entry expires.
- If a connection attempt fails to authenticate with the cached credentials, the plugin forces an immediate re-fetch and retries once, which covers the common case where rotation happened between two connections.
- During the brief window in which a rotation is in progress, you can have the plugin retry with exponential backoff by setting `secret_rotation_retry_timeout_sec` to a non-zero value (and, optionally, tuning `secret_rotation_retry_base_delay_sec`). This bridges the gap until the newly rotated credentials become valid.
