package com.wj.server.invitation.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.wj.server.invitation.domain.MembershipRow;
import java.sql.DriverManager;
import java.time.Instant;
import java.util.UUID;
import org.apache.ibatis.datasource.unpooled.UnpooledDataSource;
import org.apache.ibatis.mapping.Environment;
import org.apache.ibatis.session.Configuration;
import org.apache.ibatis.session.SqlSessionFactoryBuilder;
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

class InvitationMapperIntegrationTest {
    private static final UUID USER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000001");

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
                DockerClientFactory.instance().isDockerAvailable(),
                "Docker or Jenkins TEST_POSTGRES_* is required for the mapper integration test");
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
            .load()
            .migrate();

        try (var connection = DriverManager.getConnection(jdbcUrl, username, password);
             var statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            statement.executeUpdate(
                "insert into users (id, email, password_hash, display_name) values "
                    + "('" + USER_ID + "', 'owner@example.com', 'test-only', 'Owner')");
            statement.executeUpdate(
                "insert into memory_vaults (id, name, status) values "
                    + "('" + VAULT_ID + "', 'Mapper Test Vault', 'ACTIVE')");
            statement.executeUpdate(
                "insert into vault_memberships "
                    + "(vault_id, user_id, role, status, joined_at) values "
                    + "('" + VAULT_ID + "', '" + USER_ID + "', 'OWNER', 'ACTIVE', "
                    + "'2026-07-29T15:20:00Z')");
            connection.commit();
        }
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    @Test
    void mapsPostgresTimestampIntoVaultMembershipRow() {
        var dataSource = new UnpooledDataSource(
            "org.postgresql.Driver",
            jdbcUrl,
            username,
            password);
        var environment = new Environment(
            "integration-test",
            new JdbcTransactionFactory(),
            dataSource);
        var configuration = new Configuration(environment);
        configuration.setMapUnderscoreToCamelCase(true);
        configuration.addMapper(InvitationMapper.class);
        var sessionFactory = new SqlSessionFactoryBuilder().build(configuration);

        try (var session = sessionFactory.openSession()) {
            MembershipRow row = session.getMapper(InvitationMapper.class)
                .findActiveVaultMembers(VAULT_ID)
                .get(0);

            assertThat(row.userId()).isEqualTo(USER_ID);
            assertThat(row.vaultId()).isEqualTo(VAULT_ID);
            assertThat(row.joinedAt()).isEqualTo(Instant.parse("2026-07-29T15:20:00Z"));
        }
    }

    private static String requiredEnvironment(String name) {
        var value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " must be set");
        }
        return value;
    }
}
