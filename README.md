# Amazon Web Services (AWS) Advanced Ruby Driver Wrapper

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

The **AWS Advanced Ruby Driver Wrapper** is complementary to an existing Ruby database driver and aims to extend the functionality of the driver to enable applications to take full advantage of the features of clustered databases such as Amazon Aurora. In other words, the AWS Advanced Ruby Driver Wrapper does not connect directly to any database, but enables support of AWS and Aurora functionalities on top of an underlying Ruby driver of the user's choice. This approach enables service-specific enhancements without requiring users to change their workflow with their existing Ruby drivers and tooling.

The wrapper integrates with [ActiveRecord](https://guides.rubyonrails.org/active_record_basics.html) by providing drop-in `aws_mysql2` and `aws_postgresql` adapters that sit on top of the community [`mysql2`](https://rubygems.org/gems/mysql2) and [`pg`](https://rubygems.org/gems/pg) drivers.

## About the Wrapper

Hosting a database cluster in the cloud via Aurora provides users with sets of features and configurations to obtain maximum performance and availability, such as database failover. However, at the moment, most existing drivers do not currently support those functionalities or are not able to entirely take advantage of them.

The main idea behind the AWS Advanced Ruby Driver Wrapper is to add a software layer on top of an existing Ruby driver that would enable all the enhancements brought by Aurora, without requiring users to change their workflow with their databases and existing Ruby drivers.

### What is Failover?

In an Amazon Aurora database cluster, **failover** is a mechanism by which Aurora automatically repairs the cluster status when a primary DB instance becomes unavailable. It achieves this goal by electing an Aurora Replica to become the new primary DB instance, so that the DB cluster can provide maximum availability to a primary read-write DB instance. The AWS Advanced Ruby Driver Wrapper is designed to understand the situation and coordinate with the cluster in order to provide minimal downtime and allow connections to be very quickly restored in the event of a DB instance failure.

### Benefits of the AWS Advanced Ruby Driver Wrapper

Although Aurora is able to provide maximum availability through the use of failover, existing client drivers do not currently support this functionality. This is partially due to the time required for the DNS of the new primary DB instance to be fully resolved in order to properly direct the connection. The AWS Advanced Ruby Driver Wrapper allows customers to continue using their existing community drivers in addition to having the wrapper fully exploit failover behavior by maintaining a cache of the Aurora cluster topology and each DB instance's role (Aurora Replica or primary DB instance). This topology is provided via a direct query to the Aurora DB, essentially providing a shortcut to bypass the delays caused by DNS resolution. With this knowledge, the wrapper can more closely monitor the Aurora DB cluster status so that a connection to the new primary DB instance can be established as fast as possible.

### Seamless AWS Authentication Service Integration

Built-in support for [AWS Identity and Access Management (IAM)](https://aws.amazon.com/iam/) authentication eliminates the need to manage database passwords, while [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/) integration provides secure credential management for services that require password-based authentication.

### Modular Plugin Architecture

The plugin-based design ensures applications only load the functionality they need, reducing dependencies and overhead. The following plugins are currently available:

| Plugin                         | Description                                                                                                                                                                |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Failover                       | Reduces connection recovery time during Aurora/RDS failovers by using cached cluster topology.                                                                             |
| Global Database (GDB) Failover | Adds awareness of Amazon Aurora Global Databases to the failover logic.                                                                                                    |
| IAM Authentication             | Connects using short-lived IAM authentication tokens instead of a database password. See [Using the IAM Authentication Plugin](./docs/UsingTheIamAuthenticationPlugin.md). |
| AWS Secrets Manager            | Retrieves database credentials from AWS Secrets Manager. See [Using the AWS Secrets Manager Plugin](./docs/UsingTheAwsSecretsManagerPlugin.md).                            |
| Custom Endpoint                | Adds awareness of Aurora custom endpoints to topology and host selection.                                                                                                  |
| Blue/Green Deployment          | Adds awareness of Amazon RDS/Aurora Blue/Green deployments to minimize downtime during switchover.                                                                         |
| Initial Connection Strategy    | Controls how the initial connection to a cluster is established and verified.                                                                                              |

### Preserve Existing Workflows

The wrapper design allows developers to continue using their preferred Ruby drivers and existing ActiveRecord code while gaining service-specific enhancements. No application rewrites are required — you only change the adapter name in your database configuration.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'aws-ruby-driver-wrapper'
```

For MySQL users, also install the underlying driver:

```ruby
gem 'mysql2'
```

For PostgreSQL users, also install the underlying driver:

```ruby
gem 'pg'
```

Then execute:

```bash
bundle install
```

## Getting Started

The wrapper registers two ActiveRecord adapters — `aws_mysql2` and `aws_postgresql` — that are drop-in replacements for the standard `mysql2` and `postgresql` adapters.

Require the appropriate entry point for your database:

```ruby
# For MySQL
require 'aws_ruby_driver_wrapper/mysql'

# For PostgreSQL
require 'aws_ruby_driver_wrapper/postgresql'
```

Then set the adapter in your database configuration (for example, `config/database.yml` in a Rails application):

```yaml
# MySQL
production:
  adapter: aws_mysql2
  host: my-cluster.cluster-xxxx.us-east-1.rds.amazonaws.com
  database: mydb
  username: admin
  password: <password>

# PostgreSQL
production:
  adapter: aws_postgresql
  host: my-cluster.cluster-xxxx.us-east-1.rds.amazonaws.com
  database: mydb
  username: admin
  password: <password>
```

## Documentation

Technical documentation regarding the functionality of the AWS Advanced Ruby Driver Wrapper is maintained in this GitHub repository under the [`docs`](./docs) folder. Since the wrapper requires an underlying Ruby driver, please refer to the individual driver's documentation for driver-specific information.

| Topic                                | Documentation                                                              |
|--------------------------------------|----------------------------------------------------------------------------|
| AWS IAM Authentication Plugin        | [Using the IAM Authentication Plugin](./docs/UsingTheIamAuthenticationPlugin.md) |
| AWS Secrets Manager Plugin           | [Using the AWS Secrets Manager Plugin](./docs/UsingTheAwsSecretsManagerPlugin.md) |
| Configuring AWS Credentials          | [AWS Credentials](./docs/AwsCredentials.md)                                |
| Running the integration tests        | [Integration Tests](./docs/development-guide/IntegrationTests.md)          |

### Known Limitations

#### Amazon RDS Blue/Green Deployments

Support for Blue/Green deployments using the wrapper requires specific metadata tables. Please refer to the plugin documentation for the supported database engine versions.

## Getting Help and Opening Issues

If you encounter a bug with the AWS Advanced Ruby Driver Wrapper, we would like to hear about it.
Please search the [existing issues](https://github.com/aws/aws-advanced-ruby-driver-wrapper/issues) to see if others are also experiencing the issue before reporting the problem in a new issue. GitHub issues are intended for bug reports and feature requests.

When opening a new issue, please fill in all required fields in the issue template to help expedite the investigation process.

For all other questions, please use [GitHub discussions](https://github.com/aws/aws-advanced-ruby-driver-wrapper/discussions).

## How to Contribute

1. Set up your environment by following the directions in the [Contributing Guide](./CONTRIBUTING.md).
2. To contribute, first make a fork of this project.
3. Make any changes on your fork. Make sure you are aware of the requirements for the project.
4. Create a pull request from your fork.
5. Pull requests need to be approved and merged by maintainers into the main branch. <br />
   **Note:** Before making a pull request, run all tests and verify everything is passing.

## Other AWS Advanced Wrapper Drivers

The AWS Advanced Ruby Driver Wrapper is part of a broader family of AWS "wrapper" drivers that bring the same advanced functionality, such as failover support and IAM authentication, to other languages and database connectivity standards. If you are working outside of Ruby, you may find one of the following drivers useful:

| Driver                          | Repository                                                       |
|---------------------------------|------------------------------------------------------------------|
| AWS Advanced JDBC Wrapper       | https://github.com/aws/aws-advanced-jdbc-wrapper                 |
| AWS Advanced Python Wrapper     | https://github.com/aws/aws-advanced-python-wrapper               |
| AWS Advanced NodeJS Wrapper     | https://github.com/aws/aws-advanced-nodejs-wrapper               |
| AWS Advanced Go Wrapper         | https://github.com/aws/aws-advanced-go-wrapper                   |
| AWS Advanced .NET Wrapper       | https://github.com/aws/aws-advanced-dotnet-data-provider-wrapper |
| AWS Advanced ODBC Wrapper       | https://github.com/aws/aws-advanced-odbc-wrapper                 |

## License

This software is released under the Apache 2.0 license.
