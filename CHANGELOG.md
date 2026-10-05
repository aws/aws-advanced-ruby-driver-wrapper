# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/#semantic-versioning-200).

## [Unreleased]

### :bug: Fixed
- Fixed the `aws_postgresql` ActiveRecord adapter passing ActiveRecord-only `database.yml` keys, such as the Rails 8.1 pool settings (`max_connections`, `min_connections`, `keepalive`, `max_age`) and multi-database settings (`replica`, `migrations_paths`, `database_tasks`), to `pg`, which rejected them with `PG::Error: invalid connection option` ([PR #191](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/191)).
- Fixed the `aws_mysql2` ActiveRecord adapter dropping the `flags`, `encoding`, `socket`, and `reconnect` client options, which removed ActiveRecord's `FOUND_ROWS` flag so that statements such as `update_all` reported changed rows instead of matched rows ([PR #193](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/193)).
- Fixed the `aws_postgresql` and `aws_mysql2` ActiveRecord adapters not translating connection errors the way the standard adapters do, so a missing database was not reported as `ActiveRecord::NoDatabaseError` and `db:prepare` (and `bin/setup`) failed instead of creating it ([PR #193](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/193)).
- Fixed the `aws_postgresql` and `aws_mysql2` ActiveRecord adapters keeping ActiveRecord's prepared statement cache after a successful failover, so every query prepared before the failover failed on that connection with `Method invoked against old connection` until the process restarted ([PR #TBD](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/TBD), [documentation](https://aws.github.io/aws-advanced-wrapper-docs/ruby/enhanced-failover)).

## [1.0.0] - 2026-10-05

The Amazon Web Services (AWS) Advanced Ruby Driver Wrapper allows an application to take advantage of the features of clustered Aurora databases.

### Added
- Support for MySQL and PostgreSQL, usable in two ways:
  - Direct connections through the wrapped community driver via the `WrapperPgConnection` (on top of [`pg`](https://rubygems.org/gems/pg)) and `WrapperMysql2Client` (on top of [`mysql2`](https://rubygems.org/gems/mysql2)), requiring only a change of the connection class.
  - Drop-in [ActiveRecord](https://guides.rubyonrails.org/active_record_basics.html) adapters `aws_postgresql` and `aws_mysql2` that replace the community `postgresql` and `mysql2` adapters.
- [Failover Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/enhanced-failover).
- [Global Database Failover Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/gdb-failover).
- [AWS IAM Authentication Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/iam-authentication).
- [AWS Secrets Manager Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/aws-secrets-manager).
- [Custom Endpoint Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/custom-endpoint).
- [Blue/Green Deployment Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/blue-green).
- [Initial Connection Strategy Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/initial-connection-strategy).
- [KMS Encryption Plugin](https://aws.github.io/aws-advanced-wrapper-docs/ruby/using-plugins/kms-encryption).

[1.0.0]: https://github.com/aws/aws-advanced-ruby-driver-wrapper/releases/tag/1.0.0
