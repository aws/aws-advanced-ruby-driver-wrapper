/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package integration.host;

public class TestEnvironmentConfiguration {

  public boolean noDocker =
      Boolean.parseBoolean(System.getProperty("exclude-docker", "false"));
  public boolean noAurora =
      Boolean.parseBoolean(System.getProperty("exclude-aurora", "false"));
  public boolean noMultiAzCluster =
      Boolean.parseBoolean(System.getProperty("exclude-multi-az-cluster", "false"));
  public boolean noMultiAzInstance =
      Boolean.parseBoolean(System.getProperty("exclude-multi-az-instance", "false"));
  public boolean noPerformance =
      Boolean.parseBoolean(System.getProperty("exclude-performance", "false"));
  public boolean noMysqlEngine =
      Boolean.parseBoolean(System.getProperty("exclude-mysql-engine", "false"));
  public boolean noMysqlDriver =
      Boolean.parseBoolean(System.getProperty("exclude-mysql-driver", "false"));
  public boolean noPgEngine =
      Boolean.parseBoolean(System.getProperty("exclude-pg-engine", "false"));
  public boolean noPgDriver =
      Boolean.parseBoolean(System.getProperty("exclude-pg-driver", "false"));
  public boolean noFailover =
      Boolean.parseBoolean(System.getProperty("exclude-failover", "false"));
  public boolean noIam =
      Boolean.parseBoolean(System.getProperty("exclude-iam", "false"));
  public boolean noSecretsManager =
      Boolean.parseBoolean(System.getProperty("exclude-secrets-manager", "false"));
  public boolean excludeRuby33 =
    Boolean.parseBoolean(System.getProperty("exclude-ruby-3-3", "false"));
  public boolean excludeRuby40 =
    Boolean.parseBoolean(System.getProperty("exclude-ruby-4-0", "false"));
  public boolean testEncryptionOnly =
      Boolean.parseBoolean(System.getProperty("test-encryption-only", "false"));
  public boolean testMetricsOnly =
      Boolean.parseBoolean(System.getProperty("test-metrics-only", "false"));

  public boolean noInstances1 =
      Boolean.parseBoolean(System.getProperty("exclude-instances-1", "false"));
  public boolean noInstances2 =
      Boolean.parseBoolean(System.getProperty("exclude-instances-2", "false"));
  public boolean noInstances3 =
      Boolean.parseBoolean(System.getProperty("exclude-instances-3", "false"));
  public boolean noInstances5 =
      Boolean.parseBoolean(System.getProperty("exclude-instances-5", "false"));

  public boolean noTracesTelemetry =
      Boolean.parseBoolean(System.getProperty("exclude-traces-telemetry", "false"));
  public boolean noMetricsTelemetry =
      Boolean.parseBoolean(System.getProperty("exclude-metrics-telemetry", "false"));
  public boolean noBlueGreen =
      Boolean.parseBoolean(System.getProperty("exclude-bg", "true"));
  public boolean testBlueGreenOnly =
      Boolean.parseBoolean(System.getProperty("test-bg-only", "false"));
  public boolean testValkeyCache =
      Boolean.parseBoolean(System.getProperty("test-valkey-cache", "false"));

  public String includeTags = System.getProperty("test-include-tags");
  public String excludeTags = System.getProperty("test-exclude-tags");

  public String rdsDbRegion = System.getenv("RDS_DB_REGION");

  public boolean reuseRdsDb = Boolean.parseBoolean(System.getenv("REUSE_RDS_DB"));
  public String rdsDbName = System.getenv("RDS_DB_NAME"); // "cluster-mysql", "instance-name", "cluster-multi-az-name"
  public String rdsDbDomain =
      System.getenv("RDS_DB_DOMAIN"); // "XYZ.us-west-2.rds.amazonaws.com"

  public String rdsEndpoint =
      System.getenv("RDS_ENDPOINT"); // "https://rds-int.amazon.com"

  // Expected values: "latest", "default", or engine version, for example, "15.4"
  // If left as empty, will use default version
  public String mysqlVersion =
      System.getenv("MYSQL_VERSION");
  public String pgVersion =
      System.getenv("PG_VERSION");

  public String dbName = System.getenv("DB_DATABASE_NAME");
  public String dbUsername = System.getenv("DB_USERNAME");
  public String dbPassword = System.getenv("DB_PASSWORD");

  public String awsAccessKeyId = System.getenv("AWS_ACCESS_KEY_ID");
  public String awsSecretAccessKey = System.getenv("AWS_SECRET_ACCESS_KEY");
  public String awsSessionToken = System.getenv("AWS_SESSION_TOKEN");
  public String kmsKeyId = System.getenv("KMS_KEY_ID");
  public String iamUser = System.getenv("IAM_USER");

}
