import org.gradle.api.tasks.testing.logging.TestExceptionFormat.*
import org.gradle.api.tasks.testing.logging.TestLogEvent.*

plugins {
    id("java")
}

group = "software.amazon.ruby.integration.tests"
version = "1.0-SNAPSHOT"

sourceSets {
    test {
        java.srcDirs("src/test/java")
        resources.srcDirs("src/test/resources")
    }
}

repositories {
    mavenCentral()
}

dependencies {
  testImplementation("org.junit.platform:junit-platform-commons:1.11.3")
  testImplementation("org.junit.platform:junit-platform-engine:1.11.0")
  testImplementation("org.junit.platform:junit-platform-launcher:1.11.3")
  testImplementation("org.junit.platform:junit-platform-suite-engine:1.11.3")
  testImplementation("org.junit.jupiter:junit-jupiter-api:5.11.3")
  testImplementation("org.junit.jupiter:junit-jupiter-params:5.10.2")
  testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine")

  testImplementation("org.apache.commons:commons-dbcp2:2.12.0")
  testImplementation("org.postgresql:postgresql:42.7.10")
  testImplementation("com.mysql:mysql-connector-j:9.1.0")
  testImplementation("org.mariadb.jdbc:mariadb-java-client:3.5.6")
  testImplementation("com.zaxxer:HikariCP:4.0.3") // Version 4.+ is compatible with Java 8
  testImplementation("org.springframework.boot:spring-boot-starter-jdbc:2.7.13") // 2.7.13 is the last version compatible with Java 8
  testImplementation("org.mockito:mockito-inline:4.11.0") // 4.11.0 is the last version compatible with Java 8
  testImplementation("software.amazon.awssdk:ec2:2.42.38")
  testImplementation("software.amazon.awssdk:rds:2.42.38")
  testImplementation("software.amazon.awssdk:sts:2.42.38")
  // Note: all org.testcontainers dependencies should have the same version
  testImplementation("org.testcontainers:testcontainers:1.21.4")
  testImplementation("org.testcontainers:mysql:1.21.4")
  testImplementation("org.testcontainers:postgresql:1.21.4")
  testImplementation("org.testcontainers:mariadb:1.21.4")
  testImplementation("org.testcontainers:junit-jupiter:1.21.4")
  testImplementation("org.testcontainers:toxiproxy:1.21.4")
  testImplementation("org.apache.commons:commons-pool2:2.11.1")
  testImplementation("org.apache.poi:poi-ooxml:5.3.0")
  testImplementation("org.slf4j:slf4j-simple:2.0.13")
  testImplementation("com.fasterxml.jackson.core:jackson-databind:2.17.1")
  testImplementation("com.amazonaws:aws-xray-recorder-sdk-core:2.18.2")
  testImplementation("io.opentelemetry:opentelemetry-sdk:1.42.1")
  testImplementation("io.opentelemetry:opentelemetry-sdk-metrics:1.43.0")
  testImplementation("io.opentelemetry:opentelemetry-exporter-otlp:1.44.1")
  testImplementation("de.vandermeer:asciitable:0.3.2")
  testImplementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.19.2")
  val arch = System.getProperty("os.arch").let {
    when (it) {
      "aarch64", "arm64" -> "aarch_64"
      else -> "x86_64"
    }
  }
  val isMusl = try {
    val process = ProcessBuilder("ldd", "--version").redirectErrorStream(true).start()
    val output = process.inputStream.bufferedReader().readText()
    process.waitFor()
    output.contains("musl")
  } catch (e: Exception) {
    // If ldd doesn't exist, check for Alpine marker
    File("/etc/alpine-release").exists()
  }
  val glideClassifier = if (isMusl) "linux_musl-$arch" else "linux-$arch"
  testImplementation("io.valkey:valkey-glide:2.3.0:$glideClassifier")
}

tasks.processTestResources {
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}

tasks.test {
    filter.excludeTestsMatching("integration.*")
}

tasks.withType<Test> {
    useJUnitPlatform()
    outputs.upToDateWhen { false }
    testLogging {
        events(PASSED, FAILED, SKIPPED)
        showStandardStreams = true
        exceptionFormat = FULL
        showExceptions = true
        showCauses = true
        showStackTraces = true
    }

    reports.junitXml.required.set(true)
    reports.html.required.set(false)

    systemProperty("java.util.logging.config.file", "${project.layout.buildDirectory.get()}/resources/test/logging-test.properties")

    if (System.getProperty("os.name", "").lowercase().contains("windows")) {
        environment("DOCKER_HOST", System.getenv("DOCKER_HOST") ?: "tcp://localhost:2377")
        environment("TESTCONTAINERS_RYUK_DISABLED", "true")
    }
}

tasks.register<Test>("test-ruby-4.0-mysql") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-traces-telemetry", "true")
        systemProperty("exclude-metrics-telemetry", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

tasks.register<Test>("test-ruby-4.0-pg") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-traces-telemetry", "true")
        systemProperty("exclude-metrics-telemetry", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

tasks.register<Test>("test-ruby-3.3-mysql") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-ruby-4-0", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-traces-telemetry", "true")
        systemProperty("exclude-metrics-telemetry", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

tasks.register<Test>("test-ruby-3.3-pg") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-ruby-4-0", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-traces-telemetry", "true")
        systemProperty("exclude-metrics-telemetry", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

tasks.register<Test>("test-docker") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    environment("AWS_ACCESS_KEY_ID", System.getenv("AWS_ACCESS_KEY_ID") ?: "")
    environment("AWS_SECRET_ACCESS_KEY", System.getenv("AWS_SECRET_ACCESS_KEY") ?: "")
    environment("AWS_SESSION_TOKEN", System.getenv("AWS_SESSION_TOKEN") ?: "")
    doFirst {
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
    }
}

tasks.register<Test>("test-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
    }
}

tasks.register<Test>("test-pg-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
    }
}

tasks.register<Test>("test-mysql-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
    }
}

tasks.register<Test>("test-multi-az") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("test-pg-multi-az") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("test-mysql-multi-az") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("test-pg-aurora-performance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-iam", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
    }
}

tasks.register<Test>("test-mysql-aurora-performance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-iam", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
    }
}

tasks.register<Test>("test-bgd-mysql-instance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-ruby-4-0", "true")
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-2", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("test-bgd-mysql-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-ruby-4-0", "true")
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("test-bgd-pg-instance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-ruby-4-0", "true")
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-2", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("test-bgd-pg-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-ruby-4-0", "true")
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("test-pg-aurora-multi") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-ruby-3-4", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

tasks.register<Test>("test-mysql-aurora-multi") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-ruby-3-4", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

tasks.register<Test>("test-pg-aurora-single") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-ruby-3-4", "true")
        systemProperty("exclude-instances-2", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
    }
}

// Debug

tasks.register<Test>("debug-all-environments") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("debug-docker") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
    }
}

tasks.register<Test>("debug-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
    }
}

tasks.register<Test>("debug-pg-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
    }
}

tasks.register<Test>("debug-mysql-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
    }
}

tasks.register<Test>("debug-pg-aurora-performance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-iam", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
    }
}

tasks.register<Test>("debug-mysql-aurora-performance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-iam", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
    }
}

tasks.register<Test>("debug-multi-az") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("debug-pg-multi-az") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("debug-mysql-multi-az") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-bg", "true")
    }
}

tasks.register<Test>("debug-bgd-pg-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("debug-bgd-mysql-aurora") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-1", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("debug-bgd-mysql-instance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-2", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

tasks.register<Test>("debug-bgd-pg-instance") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.debugTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-failover", "true")
        systemProperty("exclude-secrets-manager", "true")
        systemProperty("exclude-instances-2", "true")
        systemProperty("exclude-instances-3", "true")
        systemProperty("exclude-instances-5", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("test-bg-only", "true")
    }
}

// Global Database

tasks.register<Test>("test-gdb-pg") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-mysql-driver", "true")
        systemProperty("exclude-mysql-engine", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-global-database", "false")
    }
}

tasks.register<Test>("test-gdb-mysql") {
    group = "verification"
    filter.includeTestsMatching("integration.host.TestRunner.runTests")
    doFirst {
        systemProperty("exclude-docker", "true")
        systemProperty("exclude-aurora", "true")
        systemProperty("exclude-multi-az-cluster", "true")
        systemProperty("exclude-multi-az-instance", "true")
        systemProperty("exclude-bg", "true")
        systemProperty("exclude-performance", "true")
        systemProperty("exclude-pg-driver", "true")
        systemProperty("exclude-pg-engine", "true")
        systemProperty("exclude-ruby-3-3", "true")
        systemProperty("exclude-global-database", "false")
    }
}
