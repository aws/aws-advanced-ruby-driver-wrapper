# Integration Tests

## Environment Variables
To run the integration tests, please set up the following environment variables in a `.env` file at the repository root

| Environment Variable Name | Required | Description                                                                                                                                                                                                      | Example Value                                 |
|---------------------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------|
| `DB_USERNAME`             | Yes      | The username to access the database.                                                                                                                                                                             | `admin`                                       |
| `DB_PASSWORD`             | Yes      | The database cluster password.                                                                                                                                                                                   | `password`                                    |
| `DB_DATABASE_NAME`        | No       | Name of the database that will be used by the tests. The default database name is test.                                                                                                                          | `test_db_name`                                |
| `RDS_DB_NAME`             | Yes      | The database identifier for your Aurora or RDS cluster. Must be a unique value to avoid conflicting with existing clusters.                                                                                      | `db-identifier`                               |
| `RDS_DB_DOMAIN`           | No       | The existing database connection suffix. Use this variable to run against an existing database.                                                                                                                  | `XYZ.us-east-2.rds.amazonaws.com`             |
| `IAM_USER`                | No       | User within the database that is identified with AWSAuthenticationPlugin. This is used for AWS IAM Authentication and is optional                                                                                | `example_user_name`                           |
| `AWS_ACCESS_KEY_ID`       | Yes      | An AWS access key associated with an IAM user or role with RDS permissions.                                                                                                                                      | `ABCDEFGH12345EXAMPLE`                        |
| `AWS_SECRET_ACCESS_KEY`   | Yes      | The secret key associated with the provided AWS_ACCESS_KEY_ID.                                                                                                                                                   | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`    |
| `AWS_SESSION_TOKEN`       | No       | AWS Session Token for CLI, SDK, & API access. This value is for MFA credentials only. See: [temporary AWS credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_use-resources.html). | `AQoDYXdzEJr...<remainder of session token>`  |                                          |
| `REUSE_RDS_DB`            | Yes      | Set to true if you would like to use an existing cluster for your tests.                                                                                                                                         | `false`                                       |
| `RDS_DB_REGION`           | Yes      | The database region.                                                                                                                                                                                             | `us-east-2`                                   |
| `FILTER`                  | No       | Filter tests to a specific file or file:line. When unset, runs all tests in `spec/integration/container`.                                                                                                        | `spec/integration/container/failover_spec.rb` |
| `KMS_KEY_ID`              | No       | KMS master key identifier (id, ARN, or alias) used by the KMS encryption tests. Required only for the encryption suite; those specs skip when it is unset. The credentials must allow `kms:GenerateDataKey` and `kms:Decrypt` (and `kms:CreateKey`/`kms:CreateAlias`/`kms:DescribeKey` to exercise `KeyManagementUtility.create_master_key`). | `arn:aws:kms:us-east-2:123456789012:key/abcd` |
| `DEBUG_ENV`               | No       | The debugging environment, values are `VSCODE` (default) or `TERMINAL`                                                                                                                                           | `VSCODE`                                      |

## Managing Environment Variables

1. Define your environment variables in a `.env` file in the project root
2. Add the following helper function to your `~/.zshrc`:
   ```bash
   loadenv() { set -a; source "${1:-.env}"; set +a; }
   ```
3. Source your zshrc: `source ~/.zshrc`
4. Run `loadenv` from the project root to load the variables into your shell

If you need to update them, edit your `.env` file and run `loadenv` again.

## Running Tests

To run the integration tests, pick a task defined in the `build.gradle.kts` file and execute it with gradle:
```bash
./gradlew test-aurora
```

You can configure which test environments to run against by editing/adding system property values in the gradle task you have picked 
from `build.gradle.kts`.
For example, to skip mysql aurora tests you can add `systemProperty("exclude-mysql-engine", "true")` to the `test-aurora` task defined 
in `build.gradle.kts`.

### Running the KMS encryption tests

The KMS encryption specs (`spec/integration/container/kms_encryption_*_spec.rb`) run in a dedicated
"encryption-only" environment rather than alongside the normal suite, mirroring the JDBC wrapper. The
`test-encryption`, `test-pg-encryption`, and `test-mysql-encryption` gradle tasks set
`test-encryption-only=true`, which surfaces to the test container as `RUN_ENCRYPTION_ONLY` and selects
only the `kms_encryption`-tagged specs; every other task excludes them. They require a KMS master key in
`KMS_KEY_ID` and AWS credentials, and skip themselves when `KMS_KEY_ID` is unset.

```bash
KMS_KEY_ID=arn:aws:kms:us-east-2:123456789012:key/abcd ./gradlew test-mysql-encryption
KMS_KEY_ID=arn:aws:kms:us-east-2:123456789012:key/abcd ./gradlew test-pg-encryption
```

### Filtering to a specific file or test

Set the `FILTER` env var to a file path or file:line:

```bash
FILTER=spec/integration/container/failover_spec.rb ./gradlew test-aurora
FILTER=spec/integration/container/failover_spec.rb:74 ./gradlew test-aurora
```

## Debugging Tests (VS Code)

Prerequisites:
- Install the [VSCode rdbg Ruby Debugger](https://marketplace.visualstudio.com/items?itemName=KoichiSasada.vscode-rdbg) extension
- Ensure `aws-advanced-ruby-wrapper/.vscode/launch.json` contains the "Attach to Docker rdbg" configuration:
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "rdbg",
      "name": "Attach to Docker rdbg",
      "request": "attach",
      "debugPort": "localhost:5005",
      "localfs": false,
      "localfsMap": "/app:<path-to-project>/aws-advanced-ruby-wrapper"
    }
  ]
}
```

Steps:
1. Set breakpoints in your spec/lib files in VS Code
2. Run a debug gradle task:
   ```bash
   ./gradlew debug-aurora
   ```
3. Wait for "Debug server listening on 0.0.0.0:5005" in the console
4. In VS Code, go to Run and Debug, select "Attach to Docker rdbg", click the green play button
5. Execution will pause at your breakpoints

## Debugging Tests (Terminal)

If you prefer terminal-based debugging without IDE integration:

1. Run a debug gradle task:
   ```bash
   ./gradlew debug-aurora
   ```
2. Wait for "Debug server listening on 0.0.0.0:5005" in the console
3. From a separate terminal, attach:
   ```bash
   rdbg --attach localhost:5005
   ```
4. Set breakpoints dynamically:
   ```
   break spec/integration/container/failover_spec.rb:74
   continue
   ```

You can also add `debugger` statements directly in spec/lib files to pause execution at specific points.

## Why RubyMine Debugging Is Not Supported

RubyMine's "Ruby Remote Debug" configuration uses the `ruby-debug-ide`/`debase` protocol, which only supports Ruby <= 3.1. Since this project uses Ruby 3.3+, that protocol is not compatible. RubyMine does support the `debug` gem for locally-managed processes, but it has no run configuration type for attaching to an external `rdbg` server running in a Docker container.
