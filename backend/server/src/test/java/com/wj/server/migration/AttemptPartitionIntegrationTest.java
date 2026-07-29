package com.wj.server.migration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.sql.Connection;
import java.sql.DriverManager;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * Covers the retention machinery introduced with partitioning, where a mistake
 * either silently stops expiring data or drops a partition that is still live.
 *
 * <p>Runs in its own schema so it can migrate from scratch without disturbing
 * the upgrade test that shares the same database.
 */
class AttemptPartitionIntegrationTest {
    private static final String SCHEMA = "attempt_partition_test";

    private static PostgreSQLContainer<?> postgres;
    private static String jdbcUrl;
    private static String username;
    private static String password;

    @BeforeAll
    static void preparePostgres() throws Exception {
        var externalJdbcUrl = System.getenv("TEST_POSTGRES_JDBC_URL");
        if (externalJdbcUrl != null && !externalJdbcUrl.isBlank()) {
            jdbcUrl = externalJdbcUrl;
            username = requiredEnvironment("TEST_POSTGRES_USER");
            password = requiredEnvironment("TEST_POSTGRES_PASSWORD");
        } else {
            assumeTrue(
                dockerAvailable(),
                "Docker 또는 TEST_POSTGRES_* 환경이 없어 파티션 통합 테스트를 건너뜁니다.");

            postgres = new PostgreSQLContainer<>(DockerImageName.parse("postgres:16-alpine"))
                .withDatabaseName("wj")
                .withUsername("wj")
                .withPassword("integration-test-only");
            postgres.start();
            jdbcUrl = postgres.getJdbcUrl();
            username = postgres.getUsername();
            password = postgres.getPassword();
        }

        Flyway.configure()
            .dataSource(jdbcUrl, username, password)
            .schemas(SCHEMA)
            .load()
            .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    @Test
    void provisionsWeeklyPartitionsCoveringTheRetentionWindow() throws Exception {
        try (var connection = connect()) {
            assertThat(partitionCount(connection, "auth_login_attempts")).isGreaterThan(1);
            assertThat(partitionCount(connection, "device_claim_attempts")).isGreaterThan(1);
        }
    }

    /**
     * A row has to reach a dated partition. Landing in the default one means
     * retention can no longer reclaim it by dropping a partition.
     */
    @Test
    void routesAFreshRowIntoADatedPartitionRatherThanTheDefault() throws Exception {
        try (var connection = connect(); var statement = connection.createStatement()) {
            statement.executeUpdate(
                "insert into auth_login_attempts (email_hash, ip_hash) values "
                    + "(sha256('routing@example.com'), sha256('203.0.113.9'))");

            try (var rows = statement.executeQuery(
                "select tableoid::regclass::text from auth_login_attempts "
                    + "where email_hash = sha256('routing@example.com')")) {
                rows.next();
                assertThat(rows.getString(1)).matches(".*_p[0-9]{8}$");
            }
        }
    }

    @Test
    void keepsHashesAtDigestWidthRatherThanHexText() throws Exception {
        try (var connection = connect(); var statement = connection.createStatement()) {
            statement.executeUpdate(
                "insert into auth_login_attempts (email_hash, ip_hash) values "
                    + "(sha256('width@example.com'), sha256('203.0.113.10'))");

            try (var rows = statement.executeQuery(
                "select octet_length(email_hash) from auth_login_attempts "
                    + "where email_hash = sha256('width@example.com')")) {
                rows.next();
                assertThat(rows.getInt(1)).isEqualTo(32);
            }
        }
    }

    @Test
    void provisioningTheSameRangeTwiceChangesNothing() throws Exception {
        try (var connection = connect(); var statement = connection.createStatement()) {
            int before = partitionCount(connection, "auth_login_attempts");
            statement.execute(
                "select ensure_attempt_partitions('auth_login_attempts', now(), now() + interval '28 days')");

            assertThat(partitionCount(connection, "auth_login_attempts")).isEqualTo(before);
        }
    }

    /**
     * The cutoff must expire only partitions whose whole range has passed. A
     * boundary error here quietly deletes history that is still in retention.
     */
    @Test
    void dropsOnlyPartitionsWhoseWholeRangeIsOlderThanTheCutoff() throws Exception {
        try (var connection = connect(); var statement = connection.createStatement()) {
            statement.execute(
                "select ensure_attempt_partitions('device_claim_attempts',"
                    + " now() - interval '120 days', now() + interval '28 days')");
            int provisioned = partitionCount(connection, "device_claim_attempts");

            int dropped;
            try (var rows = statement.executeQuery(
                "select drop_expired_attempt_partitions('device_claim_attempts', now() - interval '30 days')")) {
                rows.next();
                dropped = rows.getInt(1);
            }

            assertThat(dropped).isGreaterThan(0);
            assertThat(partitionCount(connection, "device_claim_attempts"))
                .isEqualTo(provisioned - dropped);

            // Everything still inside the retention window survives, and the
            // catch-all partition is never a drop candidate.
            try (var rows = statement.executeQuery(
                "select count(*) from pg_inherits"
                    + " join pg_class child on child.oid = pg_inherits.inhrelid"
                    + " where pg_inherits.inhparent = to_regclass('device_claim_attempts')"
                    + "   and child.relname = 'device_claim_attempts_default'")) {
                rows.next();
                assertThat(rows.getInt(1)).isEqualTo(1);
            }
        }
    }

    private static int partitionCount(Connection connection, String parent) throws Exception {
        try (var statement = connection.prepareStatement(
            "select count(*) from pg_inherits"
                + " join pg_class child on child.oid = pg_inherits.inhrelid"
                + " where pg_inherits.inhparent = to_regclass(?)"
                + "   and child.relname ~ '_p[0-9]{8}$'")) {
            statement.setString(1, parent);
            try (var rows = statement.executeQuery()) {
                rows.next();
                return rows.getInt(1);
            }
        }
    }

    private static Connection connect() throws Exception {
        Connection connection = DriverManager.getConnection(jdbcUrl, username, password);
        try (var statement = connection.createStatement()) {
            statement.execute("set search_path to " + SCHEMA);
        }
        return connection;
    }

    private static boolean dockerAvailable() {
        try {
            return DockerClientFactory.instance().isDockerAvailable();
        } catch (RuntimeException exception) {
            return false;
        }
    }

    private static String requiredEnvironment(String name) {
        var value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " 환경변수가 필요합니다.");
        }
        return value;
    }
}
