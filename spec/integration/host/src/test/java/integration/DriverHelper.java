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

import com.mysql.cj.conf.PropertyKey;
import integration.DatabaseEngine;
import integration.DatabaseEngineDeployment;
import integration.TestEnvironmentInfo;
import java.sql.Connection;
import java.sql.Driver;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Collections;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import java.util.logging.Level;
import java.util.logging.Logger;
import org.postgresql.PGProperty;
import org.testcontainers.shaded.org.apache.commons.lang3.NotImplementedException;

public class DriverHelper {

  private static final Logger LOGGER = Logger.getLogger(DriverHelper.class.getName());

  public static String getDriverProtocol() {
    return getDriverProtocol(DatabaseEngine.MYSQL);
  }

  public static String getDriverProtocol(DatabaseEngine databaseEngine) {
    switch (databaseEngine) {
      case MYSQL:
        return "jdbc:mysql://";
      case PG:
        return "jdbc:postgresql://";
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static String getDriverProtocol(DatabaseEngine databaseEngine, Object ignored) {
    return getDriverProtocol(databaseEngine);
  }

  public static String getWrapperDriverProtocol() {
    return getWrapperDriverProtocol(DatabaseEngine.MYSQL);
  }

  public static String getWrapperDriverProtocol(DatabaseEngine databaseEngine) {
    switch (databaseEngine) {
      case MYSQL:
        return "jdbc:aws-wrapper:mysql://";
      case PG:
        return "jdbc:aws-wrapper:postgresql://";
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static String getWrapperDriverProtocol(Object ignored, Object ignored2) {
    return getWrapperDriverProtocol(DatabaseEngine.MYSQL);
  }

  public static String getDriverClassname(DatabaseEngine databaseEngine) {
    switch (databaseEngine) {
      case MYSQL:
        return "com.mysql.cj.jdbc.Driver";
      case PG:
        return "org.postgresql.Driver";
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static String getDriverClassname() {
    return getDriverClassname(DatabaseEngine.MYSQL);
  }

  // No-op overload to avoid ambiguity; host-side has no TestDriver
  public static String getDriverClassname(DatabaseEngine databaseEngine, Object ignored) {
    return getDriverClassname(databaseEngine);
  }

  public static String getDataSourceClassname() {
    return getDataSourceClassname(DatabaseEngine.MYSQL);
  }

  public static String getDataSourceClassname(DatabaseEngine databaseEngine) {
    switch (databaseEngine) {
      case MYSQL:
        return "com.mysql.cj.jdbc.MysqlDataSource";
      case PG:
        return "org.postgresql.ds.PGSimpleDataSource";
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static Class<?> getConnectionClass() {
    return getConnectionClass(DatabaseEngine.MYSQL);
  }

  public static Class<?> getConnectionClass(DatabaseEngine databaseEngine) {
    switch (databaseEngine) {
      case MYSQL:
        return com.mysql.cj.jdbc.ConnectionImpl.class;
      case PG:
        return org.postgresql.PGConnection.class;
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static String getDriverRequiredParameters() {
    return "";
  }

  public static String getDriverRequiredParameters(DatabaseEngine databaseEngine) {
    return "";
  }

  public static String getDriverRequiredParameters(DatabaseEngine databaseEngine, Object ignored) {
    return "";
  }

  public static String getHostnameSql() {
    return getHostnameSql(DatabaseEngine.MYSQL);
  }

  public static String getHostnameSql(DatabaseEngine databaseEngine) {
    switch (databaseEngine) {
      case MYSQL:
      case PG:
        return "SELECT pg_catalog.inet_server_addr()";
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static void setConnectTimeout(Properties props, long timeout, TimeUnit timeUnit) {
    setConnectTimeout(DatabaseEngine.MYSQL, props, timeout, timeUnit);
  }

  public static void setConnectTimeout(
      DatabaseEngine databaseEngine, Properties props, long timeout, TimeUnit timeUnit) {
    switch (databaseEngine) {
      case MYSQL:
        props.setProperty(
            PropertyKey.connectTimeout.getKeyName(), String.valueOf(timeUnit.toMillis(timeout)));
        break;
      case PG:
        props.setProperty(
            PGProperty.CONNECT_TIMEOUT.getName(), String.valueOf(timeUnit.toSeconds(timeout)));
        break;
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static void setConnectTimeout(
      Object ignored, Properties props, long timeout, TimeUnit timeUnit) {
    setConnectTimeout(props, timeout, timeUnit);
  }

  public static void setSocketTimeout(Properties props, long timeout, TimeUnit timeUnit) {
    setSocketTimeout(DatabaseEngine.MYSQL, props, timeout, timeUnit);
  }

  public static void setSocketTimeout(
      DatabaseEngine databaseEngine, Properties props, long timeout, TimeUnit timeUnit) {
    switch (databaseEngine) {
      case MYSQL:
        props.setProperty(
            PropertyKey.socketTimeout.getKeyName(), String.valueOf(timeUnit.toMillis(timeout)));
        break;
      case PG:
        props.setProperty(
            PGProperty.SOCKET_TIMEOUT.getName(), String.valueOf(timeUnit.toSeconds(timeout)));
        break;
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static void setSocketTimeout(
      Object ignored, Properties props, long timeout, TimeUnit timeUnit) {
    setSocketTimeout(props, timeout, timeUnit);
  }

  public static void setTcpKeepAlive(Properties props, boolean enabled) {
    setTcpKeepAlive(DatabaseEngine.MYSQL, props, enabled);
  }

  public static void setTcpKeepAlive(DatabaseEngine databaseEngine, Properties props, boolean enabled) {
    switch (databaseEngine) {
      case MYSQL:
        props.setProperty(PropertyKey.tcpKeepAlive.getKeyName(), String.valueOf(enabled));
        break;
      case PG:
        props.setProperty(PGProperty.TCP_KEEP_ALIVE.getName(), String.valueOf(enabled));
        break;
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static void setTcpKeepAlive(Object ignored, Properties props, boolean enabled) {
    setTcpKeepAlive(props, enabled);
  }

  public static void setMonitoringConnectTimeout(
      Properties props, long timeout, TimeUnit timeUnit) {
    setMonitoringConnectTimeout(DatabaseEngine.MYSQL, props, timeout, timeUnit);
  }

  public static void setMonitoringConnectTimeout(
      DatabaseEngine databaseEngine, Properties props, long timeout, TimeUnit timeUnit) {
    switch (databaseEngine) {
      case MYSQL:
        props.setProperty(
            "monitoring-" + PropertyKey.connectTimeout.getKeyName(),
            String.valueOf(timeUnit.toMillis(timeout)));
        break;
      case PG:
        props.setProperty(
            "monitoring-" + PGProperty.CONNECT_TIMEOUT.getName(),
            String.valueOf(timeUnit.toSeconds(timeout)));
        break;
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static void setMonitoringConnectTimeout(
      Object ignored, Properties props, long timeout, TimeUnit timeUnit) {
    setMonitoringConnectTimeout(props, timeout, timeUnit);
  }

  public static void setMonitoringSocketTimeout(Properties props, long timeout, TimeUnit timeUnit) {
    setMonitoringSocketTimeout(DatabaseEngine.MYSQL, props, timeout, timeUnit);
  }

  public static void setMonitoringSocketTimeout(
      DatabaseEngine databaseEngine, Properties props, long timeout, TimeUnit timeUnit) {
    switch (databaseEngine) {
      case MYSQL:
        props.setProperty(
            "monitoring-" + PropertyKey.socketTimeout.getKeyName(),
            String.valueOf(timeUnit.toMillis(timeout)));
        break;
      case PG:
        props.setProperty(
            "monitoring-" + PGProperty.SOCKET_TIMEOUT.getName(),
            String.valueOf(timeUnit.toSeconds(timeout)));
        break;
      default:
        throw new NotImplementedException(databaseEngine.toString());
    }
  }

  public static void setMonitoringSocketTimeout(
      Object ignored, Properties props, long timeout, TimeUnit timeUnit) {
    setMonitoringSocketTimeout(props, timeout, timeUnit);
  }

  public static void unregisterAllDrivers() throws SQLException {
    List<Driver> registeredDrivers = Collections.list(DriverManager.getDrivers());
    for (Driver d : registeredDrivers) {
      try {
        DriverManager.deregisterDriver(d);
      } catch (SQLException ex) {
        LOGGER.log(Level.FINEST, "Can't deregister driver " + d.getClass().getName(), ex);
        throw ex;
      }
    }
  }

  public static void registerDriver(DatabaseEngine engine) {
    try {
      Class.forName(DriverHelper.getDriverClassname(engine));
    } catch (ClassNotFoundException e) {
      throw new RuntimeException(
          "Driver not found: "
              + DriverHelper.getDriverClassname(engine),
          e);
    }
  }

  public static Connection getDriverConnection(TestEnvironmentInfo info) throws SQLException {
    String url;
    switch (info.getRequest().getDatabaseEngineDeployment()) {
      case AURORA:
      case RDS_MULTI_AZ_CLUSTER:
        url = String.format(
            "%s%s:%d/%s",
            DriverHelper.getDriverProtocol(info.getRequest().getDatabaseEngine()),
            info.getDatabaseInfo().getClusterEndpoint(),
            info.getDatabaseInfo().getClusterEndpointPort(),
            info.getDatabaseInfo().getDefaultDbName());
        break;
      case DOCKER:
      case RDS_MULTI_AZ_INSTANCE:
        url = String.format(
            "%s%s:%d/%s",
            DriverHelper.getDriverProtocol(info.getRequest().getDatabaseEngine()),
            info.getDatabaseInfo().getInstances().get(0).getHost(),
            info.getDatabaseInfo().getInstances().get(0).getPort(),
            info.getDatabaseInfo().getDefaultDbName());
        break;
      default:
        throw new UnsupportedOperationException(info.getRequest().getDatabaseEngineDeployment().toString());
    }
    return DriverManager.getConnection(url, info.getDatabaseInfo().getUsername(), info.getDatabaseInfo().getPassword());
  }
}
