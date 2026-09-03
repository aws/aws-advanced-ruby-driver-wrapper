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

package integration;

public class TestEnvironmentInfo {

  private TestEnvironmentRequest request;

  private String awsAccessKeyId;
  private String awsSecretAccessKey;
  private String awsSessionToken;

  private String region;
  private String rdsEndpoint;
  private String rdsDbName;
  private String iamUsername;

  private TestDatabaseInfo databaseInfo;
  private TestDatabaseInfo valkeyServerInfo;
  private String valkeyServerUsername;
  private String valkeyServerPassword;
  private TestProxyDatabaseInfo proxyDatabaseInfo;
  private String databaseEngine;
  private String databaseEngineVersion;
  private TestTelemetryInfo tracesTelemetryInfo;
  private TestTelemetryInfo metricsTelemetryInfo;

  private String blueGreenDeploymentId;

  private String clusterParameterGroupName = null;

  // Random alphanumeric combination that is used to form a test cluster name or an instance name.
  private String randomBase = null;

  // Global Database fields
  private String globalClusterEndpoint;
  private String globalClusterIdentifier;
  private String primaryRegion;
  private String secondaryRegion;
  private String secondaryClusterEndpoint;
  private String secondaryClusterIdentifier;

  // Secondary-region database + proxy info (mirror of databaseInfo / proxyDatabaseInfo, for the
  // secondary GDB region). Populated for AURORA_GLOBAL deployments so the test container can reach
  // and proxy region-B instances.
  private TestDatabaseInfo secondaryDatabaseInfo;
  private TestProxyDatabaseInfo secondaryProxyDatabaseInfo;

  public TestDatabaseInfo getDatabaseInfo() {
    return this.databaseInfo;
  }

  public TestDatabaseInfo getValkeyServerInfo() {
    return this.valkeyServerInfo;
  }

  public String getValkeyServerUsername() {
    return this.valkeyServerUsername;
  }

  public String getValkeyServerPassword() {
    return this.valkeyServerPassword;
  }

  public TestProxyDatabaseInfo getProxyDatabaseInfo() {
    return this.proxyDatabaseInfo;
  }

  public String getDatabaseEngine() {
    return databaseEngine;
  }

  public String getDatabaseEngineVersion() {
    return databaseEngineVersion;
  }

  public TestTelemetryInfo getTracesTelemetryInfo() {
    return this.tracesTelemetryInfo;
  }

  public TestTelemetryInfo getMetricsTelemetryInfo() {
    return this.metricsTelemetryInfo;
  }

  public TestEnvironmentRequest getRequest() {
    return this.request;
  }

  public String getAwsAccessKeyId() {
    return this.awsAccessKeyId;
  }

  public String getAwsSecretAccessKey() {
    return this.awsSecretAccessKey;
  }

  public String getAwsSessionToken() {
    return this.awsSessionToken;
  }

  public String getRegion() {
    return this.region;
  }

  public String getRdsEndpoint() {
    return this.rdsEndpoint;
  }

  public String getRdsDbName() {
    return this.rdsDbName;
  }

  public String getIamUsername() {
    return this.iamUsername;
  }

  public void setRequest(TestEnvironmentRequest request) {
    this.request = request;
  }

  public void setRegion(String region) {
    this.region = region;
  }

  public void setRdsEndpoint(String rdsEndpoint) {
    this.rdsEndpoint = rdsEndpoint;
  }

  public void setRdsDbName(String auroraClusterName) {
    this.rdsDbName = auroraClusterName;
  }

  public void setDatabaseInfo(TestDatabaseInfo databaseInfo) {
    this.databaseInfo = databaseInfo;
  }

  public void setValkeyServerInfo(TestDatabaseInfo valkeyServerInfo) {
    this.valkeyServerInfo = valkeyServerInfo;
  }

  public void setValkeyServerUsername(String valkeyServerUsername) {
    this.valkeyServerUsername = valkeyServerUsername;
  }

  public void setValkeyServerPassword(String valkeyServerPassword) {
    this.valkeyServerPassword = valkeyServerPassword;
  }

  public void setProxyDatabaseInfo(TestProxyDatabaseInfo proxyDatabaseInfo) {
    this.proxyDatabaseInfo = proxyDatabaseInfo;
  }

  public void setDatabaseEngine(String databaseEngine) {
    this.databaseEngine = databaseEngine;
  }

  public void setDatabaseEngineVersion(String databaseEngineVersion) {
    this.databaseEngineVersion = databaseEngineVersion;
  }

  public void setTracesTelemetryInfo(TestTelemetryInfo tracesTelemetryInfo) {
    this.tracesTelemetryInfo = tracesTelemetryInfo;
  }

  public void setMetricsTelemetryInfo(TestTelemetryInfo metricsTelemetryInfo) {
    this.metricsTelemetryInfo = metricsTelemetryInfo;
  }

  public void setAwsAccessKeyId(String awsAccessKeyId) {
    this.awsAccessKeyId = awsAccessKeyId;
  }

  public void setAwsSecretAccessKey(String awsSecretAccessKey) {
    this.awsSecretAccessKey = awsSecretAccessKey;
  }

  public void setAwsSessionToken(String awsSessionToken) {
    this.awsSessionToken = awsSessionToken;
  }

  public void setIamUsername(String iamUsername) {
    this.iamUsername = iamUsername;
  }

  public String getBlueGreenDeploymentId() {
    return this.blueGreenDeploymentId;
  }

  public void setBlueGreenDeploymentId(final String blueGreenDeploymentId) {
    this.blueGreenDeploymentId = blueGreenDeploymentId;
  }

  public String getClusterParameterGroupName() {
    return this.clusterParameterGroupName;
  }

  public void setClusterParameterGroupName(String clusterParameterGroupName) {
    this.clusterParameterGroupName = clusterParameterGroupName;
  }

  public String getRandomBase() {
    return this.randomBase;
  }

  public void setRandomBase(String randomBase) {
    this.randomBase = randomBase;
  }

  public String getGlobalClusterEndpoint() {
    return this.globalClusterEndpoint;
  }

  public void setGlobalClusterEndpoint(String globalClusterEndpoint) {
    this.globalClusterEndpoint = globalClusterEndpoint;
  }

  public String getGlobalClusterIdentifier() {
    return this.globalClusterIdentifier;
  }

  public void setGlobalClusterIdentifier(String globalClusterIdentifier) {
    this.globalClusterIdentifier = globalClusterIdentifier;
  }

  public String getPrimaryRegion() {
    return this.primaryRegion;
  }

  public void setPrimaryRegion(String primaryRegion) {
    this.primaryRegion = primaryRegion;
  }

  public String getSecondaryRegion() {
    return this.secondaryRegion;
  }

  public void setSecondaryRegion(String secondaryRegion) {
    this.secondaryRegion = secondaryRegion;
  }

  public String getSecondaryClusterEndpoint() {
    return this.secondaryClusterEndpoint;
  }

  public void setSecondaryClusterEndpoint(String secondaryClusterEndpoint) {
    this.secondaryClusterEndpoint = secondaryClusterEndpoint;
  }

  public String getSecondaryClusterIdentifier() {
    return this.secondaryClusterIdentifier;
  }

  public void setSecondaryClusterIdentifier(String secondaryClusterIdentifier) {
    this.secondaryClusterIdentifier = secondaryClusterIdentifier;
  }

  public TestDatabaseInfo getSecondaryDatabaseInfo() {
    return this.secondaryDatabaseInfo;
  }

  public void setSecondaryDatabaseInfo(TestDatabaseInfo secondaryDatabaseInfo) {
    this.secondaryDatabaseInfo = secondaryDatabaseInfo;
  }

  public TestProxyDatabaseInfo getSecondaryProxyDatabaseInfo() {
    return this.secondaryProxyDatabaseInfo;
  }

  public void setSecondaryProxyDatabaseInfo(TestProxyDatabaseInfo secondaryProxyDatabaseInfo) {
    this.secondaryProxyDatabaseInfo = secondaryProxyDatabaseInfo;
  }
}
