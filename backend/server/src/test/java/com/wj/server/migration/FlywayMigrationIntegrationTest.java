package com.wj.server.migration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.sql.DriverManager;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

class FlywayMigrationIntegrationTest {
    private static PostgreSQLContainer<?> postgres;
    private static String jdbcUrl;
    private static String username;
    private static String password;

    @BeforeAll
    static void preparePostgres() {
        var externalJdbcUrl = System.getenv("TEST_POSTGRES_JDBC_URL");
        if (externalJdbcUrl != null && !externalJdbcUrl.isBlank()) {
            jdbcUrl = externalJdbcUrl;
            username = requiredEnvironment("TEST_POSTGRES_USER");
            password = requiredEnvironment("TEST_POSTGRES_PASSWORD");
            return;
        }

        assumeTrue(
            DockerClientFactory.instance().isDockerAvailable(),
            "Docker 또는 Jenkins TEST_POSTGRES_* 환경이 없어 PostgreSQL 통합 테스트를 건너뜁니다.");

        postgres = new PostgreSQLContainer<>(DockerImageName.parse("postgres:16-alpine"))
            .withDatabaseName("wj")
            .withUsername("wj")
            .withPassword("integration-test-only");
        postgres.start();
        jdbcUrl = postgres.getJdbcUrl();
        username = postgres.getUsername();
        password = postgres.getPassword();
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    @Test
    void allMigrationsApplyToCleanPostgres() throws Exception {
        Flyway flyway = Flyway.configure()
            .dataSource(jdbcUrl, username, password)
            .load();

        var result = flyway.migrate();

        assertThat(result.success).isTrue();
        assertThat(result.targetSchemaVersion).isEqualTo("25");
        try (var connection = DriverManager.getConnection(
            jdbcUrl, username, password);
             var statement = connection.prepareStatement(
                 "select count(*) from information_schema.tables where table_name in "
                     + "('auth_login_attempts', 'device_credentials', 'device_events', "
                     + "'membership_request_links', 'password_reset_tokens', 'notifications')");
             var rows = statement.executeQuery()) {
            rows.next();
            assertThat(rows.getInt(1)).isEqualTo(6);
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
