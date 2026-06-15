# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

module AwsRubyDatabaseDriverWrapper
  module DialectCodes
    # MySQL variants
    GLOBAL_AURORA_MYSQL = 'global-aurora-mysql'
    AURORA_MYSQL = 'aurora-mysql'
    RDS_MYSQL = 'rds-mysql'
    MYSQL = 'mysql'
    # https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/multi-az-db-clusters-concepts.html
    MULTI_AZ_MYSQL_CLUSTER = 'multi-az-mysql-cluster'

    # PostgreSQL variants
    GLOBAL_AURORA_PG = 'global-aurora-pg'
    AURORA_PG = 'aurora-pg'
    RDS_PG = 'rds-pg'
    # https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/multi-az-db-clusters-concepts.html
    MULTI_AZ_PG_CLUSTER = 'multi-az-pg-cluster'
    PG = 'pg'

    UNKNOWN = 'unknown'
    CUSTOM = 'custom'
  end
end
