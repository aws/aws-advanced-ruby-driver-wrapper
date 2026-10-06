# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/#semantic-versioning-200).

## [Unreleased]

### :bug: Fixed
- Fixed the `aws_postgresql` ActiveRecord adapter passing ActiveRecord-only `database.yml` keys, such as the Rails 8.1 pool settings (`max_connections`, `min_connections`, `keepalive`, `max_age`) and multi-database settings (`replica`, `migrations_paths`, `database_tasks`), to `pg`, which rejected them with `PG::Error: invalid connection option` ([PR #191](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/191)).
- Fixed the `aws_mysql2` ActiveRecord adapter dropping the `flags`, `encoding`, `socket`, and `reconnect` client options, which removed ActiveRecord's `FOUND_ROWS` flag so that statements such as `update_all` reported changed rows instead of matched rows ([PR #193](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/193)).
- Fixed the `aws_postgresql` and `aws_mysql2` ActiveRecord adapters not translating connection errors the way the standard adapters do, so a missing database was not reported as `ActiveRecord::NoDatabaseError` and `db:prepare` (and `bin/setup`) failed instead of creating it ([PR #193](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/193)).
- Fixed the `aws_postgresql` and `aws_mysql2` ActiveRecord adapters keeping ActiveRecord's prepared statement cache after a successful failover, so every query prepared before the failover failed on that connection with `Method invoked against old connection` until the process restarted ([PR #194](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/194), [documentation](https://aws.github.io/aws-advanced-wrapper-docs/ruby/enhanced-failover)).
- Fixed `db:drop`, `db:reset`, and `db:test:prepare` failing on Aurora PostgreSQL with `database "<name>" is being accessed by other users`. The same error occurred when running `bin/rails test` after a schema change. The cause was the wrapper's topology and Blue/Green monitors, which kept their own connections open to the database being dropped. The wrapper now stops these monitors before dropping a database and when ActiveRecord clears all its connections ([PR #195](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/195)).
- Fixed forked processes, such as Puma workers with `preload_app!`, Unicorn workers, and Resque jobs, inheriting the parent's background monitors after their threads had stopped, so the cluster topology never refreshed in the child and failover there could not find the new writer. A forked child now starts its own monitors and leaves the parent's monitoring connections open ([PR #196](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/196)).
- Fixed Action Cable's PostgreSQL subscription adapter (`adapter: postgresql` in `cable.yml`) refusing to run on the `aws_postgresql` ActiveRecord adapter with `The Active Record database must be PostgreSQL in order to use the PostgreSQL Action Cable storage adapter`, which also stopped Turbo Stream broadcasts ([PR #197](https://github.com/aws/aws-advanced-ruby-driver-wrapper/pull/197)).

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
