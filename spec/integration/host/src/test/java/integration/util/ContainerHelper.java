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

package integration.util;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.github.dockerjava.api.DockerClient;
import com.github.dockerjava.api.command.ExecCreateCmd;
import com.github.dockerjava.api.command.ExecCreateCmdResponse;
import com.github.dockerjava.api.command.InspectContainerResponse;
import com.github.dockerjava.api.exception.DockerException;
import eu.rekawek.toxiproxy.ToxiproxyClient;
import integration.DatabaseEngine;
import integration.DatabaseEngineDeployment;
import integration.TargetRubyVersion;
import integration.TestEnvironmentFeatures;
import integration.TestEnvironmentInfo;
import integration.TestEnvironmentRequest;
import integration.TestInstanceInfo;
import java.io.File;
import java.io.IOException;
import java.time.Duration;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.function.Consumer;
import java.util.function.Function;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.BindMode;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.InternetProtocol;
import org.testcontainers.containers.MySQLContainer;
import org.testcontainers.containers.Network;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.ToxiproxyContainer;
import org.testcontainers.containers.output.FrameConsumerResultCallback;
import org.testcontainers.containers.output.OutputFrame;
import org.testcontainers.containers.wait.strategy.LogMessageWaitStrategy;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.images.builder.ImageFromDockerfile;
import org.testcontainers.images.builder.dockerfile.DockerfileBuilder;
import org.testcontainers.utility.DockerImageName;
import org.testcontainers.utility.MountableFile;
import org.testcontainers.utility.TestEnvironment;
import integration.util.StringUtils;

@SuppressWarnings("unchecked")
public class ContainerHelper {

  private static final String MYSQL_CONTAINER_IMAGE_NAME = "mysql:8.0.31";
  private static final String POSTGRES_CONTAINER_IMAGE_NAME = "postgres:latest";
  private static final String VALKEY_CONTAINER_IMAGE_NAME = "valkey/valkey:8.1";
  // Note: this image version may need to be occasionally updated to keep it up-to-date and prevent toxiproxy issues.
  private static final DockerImageName TOXIPROXY_IMAGE =
      DockerImageName.parse("ghcr.io/shopify/toxiproxy:2.11.0");

  private static final int PROXY_CONTROL_PORT = 8474;
  private static final int PROXY_PORT = 8666;

  private static final String XRAY_TELEMETRY_IMAGE_NAME = "amazon/aws-xray-daemon";
  private static final String OTLP_TELEMETRY_IMAGE_NAME = "amazon/aws-otel-collector";

  private static final String RETRIEVE_TOPOLOGY_SQL_POSTGRES =
      "SELECT SERVER_ID, SESSION_ID FROM pg_catalog.aurora_replica_status() "
          + "ORDER BY CASE WHEN SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID' THEN 0 ELSE 1 END";
  private static final String RETRIEVE_TOPOLOGY_SQL_MYSQL =
      "SELECT SERVER_ID, SESSION_ID FROM information_schema.replica_host_status "
          + "ORDER BY IF(SESSION_ID = 'MASTER_SESSION_ID', 0, 1)";
  private static final String SERVER_ID = "SERVER_ID";

  public Long runCmd(GenericContainer<?> container, String... cmd)
      throws IOException, InterruptedException {
    System.out.println("==== Container console feed ==== >>>>");
    Consumer<OutputFrame> consumer = new ConsoleConsumer();
    Long exitCode = execInContainer(container, consumer, cmd);
    System.out.println("==== Container console feed ==== <<<<");
    return exitCode;
  }

  public Long runCmdInDirectory(GenericContainer<?> container, String workingDirectory, String... cmd)
      throws IOException, InterruptedException {
    System.out.println("==== Container console feed ==== >>>>");
    Consumer<OutputFrame> consumer = new ConsoleConsumer();
    Long exitCode = execInContainer(container, workingDirectory, consumer, cmd);
    System.out.println("==== Container console feed ==== <<<<");
    return exitCode;
  }

  public void runTest(
    GenericContainer<?> container,
    String task,
    String includeTags,
    String excludeTags,
    TargetRubyVersion targetRubyVersion)
    throws IOException, InterruptedException {
    System.out.println("==== Container console feed ==== >>>>");
    Consumer<OutputFrame> consumer = new ConsoleConsumer(true);
    execInContainer(container, consumer, "printenv", "TEST_ENV_DESCRIPTION");

    Long exitCode = execInContainer(container, consumer, "bundle", "install");
    assertEquals(0, exitCode, "Bundle install failed.");

    String filter = System.getenv("FILTER");

    ArrayList<String> commands = new ArrayList<>();
    commands.add("bundle");
    commands.add("exec");
    commands.add("rspec");
    commands.add("--format");
    commands.add("documentation");
    commands.add(StringUtils.isNullOrEmpty(filter) ? "spec/integration/container" : filter);
    if (!StringUtils.isNullOrEmpty(includeTags)) {
      commands.add("--tag");
      commands.add(includeTags);
    }
    if (!StringUtils.isNullOrEmpty(excludeTags)) {
      commands.add("--tag");
      commands.add("~" + excludeTags);
    }

    exitCode = execInContainer(container, consumer, commands.toArray(new String[0]));
    System.out.println("==== Container console feed ==== <<<<");
    assertEquals(0, exitCode, "Some tests failed.");
  }

  public void debugTest(
    GenericContainer<?> container,
    String task,
    String includeTags,
    String excludeTags,
    TargetRubyVersion targetRubyVersion)
    throws IOException, InterruptedException {
    System.out.println("==== Container console feed ==== >>>>");
    Consumer<OutputFrame> consumer = new ConsoleConsumer(true);
    execInContainer(container, consumer, "printenv", "TEST_ENV_DESCRIPTION");

    Long exitCode = execInContainer(container, consumer, "bundle", "install");
    assertEquals(0, exitCode, "Bundle install failed.");

    String filter = System.getenv("FILTER");
    integration.DebugEnv debugEnv = integration.DebugEnv.fromEnv();
    String testPath = StringUtils.isNullOrEmpty(filter) ? "spec/integration/container" : filter;

    ArrayList<String> commands = new ArrayList<>();
    commands.add("bundle");
    commands.add("exec");
    commands.add("rdbg");
    commands.add("--open");
    commands.add("--host");
    commands.add("0.0.0.0");
    commands.add("--port");
    commands.add("5005");
    commands.add("-c");
    commands.add("--");
    commands.add("rspec");

    commands.add(testPath);
    if (!StringUtils.isNullOrEmpty(includeTags)) {
      commands.add("--tag");
      commands.add(includeTags);
    }
    if (!StringUtils.isNullOrEmpty(excludeTags)) {
      commands.add("--tag");
      commands.add("~" + excludeTags);
    }

    switch (debugEnv) {
      case VSCODE:
        System.out.println("\n\n    " +
            "Debug server listening on 0.0.0.0:5005." +
            "\n    In VS Code, select 'Attach to Docker rdbg' in Run and Debug and click the green play button." +
            "\n\n");
        break;
      case TERMINAL:
        System.out.println("\n\n    " +
            "Debug server listening on 0.0.0.0:5005." +
            "\n    From a separate terminal, run: rdbg --attach localhost:5005" +
            "\n\n");
        break;
    }

    exitCode = execInContainer(container, consumer, commands.toArray(new String[0]));
    System.out.println("==== Container console feed ==== <<<<");
    assertEquals(0, exitCode, "Some tests failed.");
  }

  // This container supports traces to AWS XRay.
  public GenericContainer<?> createTelemetryXrayContainer(
      String xrayAwsRegion,
      Network network,
      String networkAlias) {

    return new FixedExposedPortContainer<>(
        new ImageFromDockerfile("xray-daemon", true)
            .withDockerfileFromBuilder(
                builder -> builder
                        .from(XRAY_TELEMETRY_IMAGE_NAME)
                        .entryPoint("/xray",
                          "-t", "0.0.0.0:2000",
                          "-b", "0.0.0.0:2000",
                          "--local-mode",
                          "--log-level", "debug",
                          "--region", xrayAwsRegion)
                        .build()))
        .withExposedPort(2000)
        .waitingFor(Wait.forLogMessage(".*Starting proxy http server on 0.0.0.0:2000.*", 1))
        .withNetworkAliases(networkAlias)
        .withNetwork(network);
  }

  // This container supports traces and metrics to AWS CloudWatch/XRay
  public GenericContainer<?> createTelemetryOtlpContainer(
      Network network,
      String networkAlias) {

    return new FixedExposedPortContainer<>(DockerImageName.parse(OTLP_TELEMETRY_IMAGE_NAME))
        .withExposedPort(2000)
        .withExposedPort(1777)
        .withExposedPort(4317)
        .withExposedPort(4318)
        .waitingFor(Wait.forLogMessage(".*Everything is ready. Begin running and processing data.*", 1))
        .withNetworkAliases(networkAlias)
        .withNetwork(network)
        .withCopyFileToContainer(
            MountableFile.forHostPath("./src/test/resources/otel-config.yaml"),
            "/etc/otel-config.yaml");

  }

  public GenericContainer<?> createTestContainer(String dockerImageName, String testContainerImageName) {
    return createTestContainer(
        dockerImageName,
        testContainerImageName,
        builder -> builder // Return directly, do not append extra run commands to the docker builder.
    );
  }

  public GenericContainer<?> createTestContainer(
      String dockerImageName,
      String testContainerImageName,
      Function<DockerfileBuilder, DockerfileBuilder> appendExtraCommandsToBuilder) {
    class FixedExposedPortContainer<T extends GenericContainer<T>> extends GenericContainer<T> {

      public FixedExposedPortContainer(ImageFromDockerfile withDockerfileFromBuilder) {
        super(withDockerfileFromBuilder);
      }

      public T withFixedExposedPort(int hostPort, int containerPort) {
        super.addFixedExposedPort(hostPort, containerPort, InternetProtocol.TCP);

        return self();
      }
    }

    // Ensure host directories exist before binding them to the container.
    // Docker will fail with "no such file or directory" if these paths are missing.
    for (String dir : new String[]{"./build/reports/tests", "./build/test-results", "./build/jacoco"}) {
      new File(dir).mkdirs();
    }

    // Pin Bundler to the exact version recorded in the project's Gemfile.lock
    // ("BUNDLED WITH"). Installing it at image-build time avoids the runtime
    // "lockfile was generated with X ... Installing Bundler X and restarting"
    // reconciliation step during `bundle install`.
    final String bundlerVersion = readBundledWithVersion(toDockerPath("../../../Gemfile.lock"));

    return new FixedExposedPortContainer<>(
      new ImageFromDockerfile(dockerImageName, true)
        .withDockerfileFromBuilder(
          builder -> appendExtraCommandsToBuilder.apply(
            withBundlerSetup(
              builder
                .from(testContainerImageName)
                .run("mkdir", "app")
                .workDir("/app"),
              bundlerVersion)
              .entryPoint("/bin/sh -c \"while true; do sleep 30; done;\"")
              .expose(5005)
          ).build()))
      .withFixedExposedPort(5005, 5005)
      .withFileSystemBind(toDockerPath("../../../Gemfile"), "/app/Gemfile", BindMode.READ_ONLY)
      .withFileSystemBind(toDockerPath("../../../Gemfile.lock"), "/app/Gemfile.lock", BindMode.READ_WRITE)
      .withFileSystemBind(toDockerPath("../../../lib"), "/app/lib", BindMode.READ_WRITE)
      .withFileSystemBind(toDockerPath("../../../spec"), "/app/spec", BindMode.READ_WRITE)
      .withFileSystemBind(toDockerPath("../../../aws-advanced-ruby-driver-wrapper.gemspec"), "/app/aws-advanced-ruby-driver-wrapper.gemspec", BindMode.READ_ONLY)
      .withPrivilegedMode(true);
  }

  /**
   * Reads the Bundler version recorded under the "BUNDLED WITH" section of a
   * Gemfile.lock. Returns {@code null} if the file or the section is absent, in
   * which case no explicit Bundler version is pinned into the image.
   */
  private static String readBundledWithVersion(String gemfileLockPath) {
    File lock = new File(gemfileLockPath);
    if (!lock.isFile()) {
      return null;
    }
    try {
      java.util.List<String> lines =
          java.nio.file.Files.readAllLines(lock.toPath(), java.nio.charset.StandardCharsets.UTF_8);
      for (int i = 0; i < lines.size(); i++) {
        if ("BUNDLED WITH".equals(lines.get(i).trim())) {
          for (int j = i + 1; j < lines.size(); j++) {
            String candidate = lines.get(j).trim();
            if (!candidate.isEmpty()) {
              return candidate.matches("\\d+\\.\\d+(\\.\\d+)?([.\\-].+)?") ? candidate : null;
            }
          }
        }
      }
    } catch (IOException e) {
      // Best-effort only; fall through to no explicit pin.
    }
    return null;
  }

  /**
   * Appends image-build steps that make the test container's dependency setup
   * deterministic and quiet by installing the exact Bundler version recorded in
   * the lockfile ("BUNDLED WITH") so `bundle install` does not reconcile and
   * restart at runtime, and by configuring Bundler for non-interactive,
   * retrying installs.
   */
  private static DockerfileBuilder withBundlerSetup(DockerfileBuilder builder, String bundlerVersion) {
    if (!StringUtils.isNullOrEmpty(bundlerVersion)) {
      builder = builder.run("gem", "install", "bundler", "-v", bundlerVersion);
    }

    // Deterministic, non-interactive Bundler behavior for the runtime install.
    // BUNDLE_FROZEN makes Gemfile.lock authoritative: the install fails fast
    // if the lock is out of sync, so local Docker and GitHub Actions runs match.
    builder = builder.env("BUNDLE_FROZEN", "true");
    builder = builder.env("BUNDLE_JOBS", "4");
    builder = builder.env("BUNDLE_RETRY", "3");

    return builder;
  }

  /**
   * Converts a relative host path to an absolute path compatible with Docker.
   * On Windows with WSL2, converts backslashes and drive letters to /mnt/... format.
   */
  private static String toDockerPath(String relativePath) {
    File file = new File(relativePath).getAbsoluteFile();
    String path = file.getPath();
    if (System.getProperty("os.name", "").toLowerCase().contains("windows")) {
      path = path.replace('\\', '/');
      if (path.length() >= 2 && path.charAt(1) == ':') {
        path = "/mnt/" + Character.toLowerCase(path.charAt(0)) + path.substring(2);
      }
    }
    return path;
  }

  protected Long execInContainer(
      GenericContainer<?> container, String workingDirectory, Consumer<OutputFrame> consumer, String... command)
      throws UnsupportedOperationException, IOException, InterruptedException {
    return execInContainer(container.getContainerInfo(), consumer, workingDirectory, command);
  }

  protected Long execInContainer(
      GenericContainer<?> container,
      Consumer<OutputFrame> consumer,
      String... command)
      throws UnsupportedOperationException, IOException, InterruptedException {
    return execInContainer(container.getContainerInfo(), consumer, null, command);
  }

  protected Long execInContainer(
      InspectContainerResponse containerInfo,
      Consumer<OutputFrame> consumer,
      String workingDir,
      String... command)
      throws UnsupportedOperationException, IOException, InterruptedException {
    if (!TestEnvironment.dockerExecutionDriverSupportsExec()) {
      // at time of writing, this is the expected result in CircleCI.
      throw new UnsupportedOperationException(
          "Your docker daemon is running the \"lxc\" driver, which doesn't support \"docker exec\".");
    }

    if (!isRunning(containerInfo)) {
      throw new IllegalStateException(
          "execInContainer can only be used while the Container is running");
    }

    final String containerId = containerInfo.getId();
    final DockerClient dockerClient = DockerClientFactory.instance().client();
    final ExecCreateCmd cmd = dockerClient
        .execCreateCmd(containerId)
        .withAttachStdout(true)
        .withAttachStderr(true)
        .withCmd(command);

    if (!StringUtils.isNullOrEmpty(workingDir)) {
      cmd.withWorkingDir(workingDir);
    }

    final ExecCreateCmdResponse execCreateCmdResponse = cmd.exec();
    try (final FrameConsumerResultCallback callback = new FrameConsumerResultCallback()) {
      callback.addConsumer(OutputFrame.OutputType.STDOUT, consumer);
      callback.addConsumer(OutputFrame.OutputType.STDERR, consumer);
      dockerClient.execStartCmd(execCreateCmdResponse.getId()).exec(callback).awaitCompletion();
    }

    return dockerClient.inspectExecCmd(execCreateCmdResponse.getId()).exec().getExitCodeLong();
  }

  protected boolean isRunning(InspectContainerResponse containerInfo) {
    try {
      return containerInfo != null
          && containerInfo.getState() != null
          && containerInfo.getState().getRunning();
    } catch (DockerException e) {
      return false;
    }
  }

  public MySQLContainer<?> createMysqlContainer(
      Network network, String networkAlias, String testDbName, String username, String password) {

    return new MySQLContainer<>(MYSQL_CONTAINER_IMAGE_NAME)
        .withNetwork(network)
        .withNetworkAliases(networkAlias)
        .withDatabaseName(testDbName)
        .withPassword(password)
        .withUsername(username)
        .withEnv("MYSQL_ROOT_PASSWORD", password)
        .withCopyFileToContainer(
            MountableFile.forHostPath("./src/test/config/standard-mysql-grant-root.sql"),
            "/docker-entrypoint-initdb.d/standard-mysql-grant-root.sql")
        .withCommand(
            "--local_infile=1",
            "--max_allowed_packet=40M",
            "--max-connections=2048",
            "--secure-file-priv=/var/lib/mysql",
            "--log-error-verbosity=4",
            "--character-set-server=utf8mb4",
            "--collation-server=utf8mb4_0900_as_cs",
            "--skip-character-set-client-handshake",
            "--log-bin-trust-function-creators=1",
            "--lower_case_table_names=2");
  }

  public PostgreSQLContainer<?> createPostgresContainer(
      Network network, String networkAlias, String testDbName, String username, String password) {

    return new PostgreSQLContainer<>(POSTGRES_CONTAINER_IMAGE_NAME)
        .withNetwork(network)
        .withNetworkAliases(networkAlias)
        .withDatabaseName(testDbName)
        .withUsername(username)
        .withPassword(password);
  }

  public ToxiproxyContainer createAndStartProxyContainer(
      final Network network,
      String networkAlias,
      String networkUrl,
      String hostname,
      int port) throws IOException {
    final ToxiproxyContainer container =
        new ToxiproxyContainer(TOXIPROXY_IMAGE)
            .withNetwork(network)
            .withNetworkAliases(networkAlias, networkUrl);
    container.start();
    final ToxiproxyClient toxiproxyClient = new ToxiproxyClient(
        container.getHost(),
        container.getMappedPort(PROXY_CONTROL_PORT));
    this.createProxy(toxiproxyClient, hostname, port);
    return container;
  }

  public GenericContainer<?> createValkeyContainer(
      Network network,
      String networkAlias,
      boolean authEnabled,
      boolean tlsEnabled) {

    GenericContainer<?> container = new GenericContainer<>(VALKEY_CONTAINER_IMAGE_NAME)
        .withNetwork(network)
        .withNetworkAliases(networkAlias);

    if (tlsEnabled) {
      // TLS uses port 6380
      container.withExposedPorts(6380);

      // Copy TLS certificates
      container
          .withCopyFileToContainer(
              MountableFile.forHostPath("./src/test/resources/certs/ca.crt"),
              "/etc/valkey/certs/ca.crt")
          .withCopyFileToContainer(
              MountableFile.forHostPath("./src/test/resources/certs/valkey.crt"),
              "/etc/valkey/certs/valkey.crt")
          .withCopyFileToContainer(
              MountableFile.forHostPath("./src/test/resources/certs/valkey.key"),
              "/etc/valkey/certs/valkey.key");

      if (authEnabled) {
        container
            .withCopyFileToContainer(
                MountableFile.forHostPath("./src/test/resources/valkey-acl.conf"),
                "/etc/valkey/valkey-acl.conf")
            .withCommand(
                "--protected-mode no",
                "--tls-port 6380",
                "--port 0",
                "--tls-cert-file /etc/valkey/certs/valkey.crt",
                "--tls-key-file /etc/valkey/certs/valkey.key",
                "--tls-ca-cert-file /etc/valkey/certs/ca.crt",
                "--tls-auth-clients no",
                "--aclfile /etc/valkey/valkey-acl.conf");
      } else {
        container.withCommand(
            "--protected-mode no",
            "--tls-port 6380",
            "--port 0",
            "--tls-cert-file /etc/valkey/certs/valkey.crt",
            "--tls-key-file /etc/valkey/certs/valkey.key",
            "--tls-ca-cert-file /etc/valkey/certs/ca.crt",
            "--tls-auth-clients no");
      }
    } else {
      // Non-TLS (existing logic)
      container.withExposedPorts(6379);

      if (authEnabled) {
        container
            .withCopyFileToContainer(
                MountableFile.forHostPath("./src/test/resources/valkey-acl.conf"),
                "/etc/valkey/valkey-acl.conf")
            .withCommand("--protected-mode no", "--aclfile /etc/valkey/valkey-acl.conf");
      } else {
        container.withCommand("--protected-mode no");
      }
    }

    return container;
  }

  public void createProxy(final ToxiproxyClient client, String hostname, int port)
      throws IOException {
    client.createProxy(
        hostname + ":" + port,
        "0.0.0.0:" + PROXY_PORT,
        hostname + ":" + port);
  }

  public ToxiproxyContainer createProxyContainer(
      final Network network, TestInstanceInfo instance, String proxyDomainNameSuffix) {
    return new ToxiproxyContainer(TOXIPROXY_IMAGE)
        .withNetwork(network)
        .withNetworkAliases(
            "proxy-instance-" + instance.getInstanceId(),
            instance.getHost() + proxyDomainNameSuffix);
  }

  public static class FixedExposedPortContainer<T extends FixedExposedPortContainer<T>> extends GenericContainer<T> {

    public FixedExposedPortContainer(ImageFromDockerfile withDockerfileFromBuilder) {
      super(withDockerfileFromBuilder);
    }

    public FixedExposedPortContainer(final DockerImageName dockerImageName) {
      super(dockerImageName);
    }

    public T withFixedExposedPort(int hostPort, int containerPort, InternetProtocol protocol) {
      super.addFixedExposedPort(hostPort, containerPort, protocol);
      return self();
    }

    public T withExposedPort(Integer port) {
      super.addExposedPort(port);
      return self();
    }
  }
}
