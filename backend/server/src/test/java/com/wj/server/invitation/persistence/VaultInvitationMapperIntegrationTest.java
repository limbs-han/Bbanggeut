package com.wj.server.invitation.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.wj.server.config.MyBatisConfig;
import com.wj.server.invitation.domain.InvitationRow;
import java.sql.DriverManager;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
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

/**
 * Covers the vault invitation write path end to end against real PostgreSQL.
 *
 * <p>The device-scoped queries were already exercised elsewhere, so a mapping
 * fault that only affects the vault projection reaches production as a 500.
 */
class VaultInvitationMapperIntegrationTest {
    private static final String TEST_SCHEMA = "vault_invitation_mapper_test";
    private static final UUID OWNER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000011");
    private static final UUID INVITEE_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000012");
    private static final UUID VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000011");
    private static final UUID DEVICE_ID =
        UUID.fromString("30000000-0000-0000-0000-000000000011");

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
        jdbcUrl = withCurrentSchema(jdbcUrl, TEST_SCHEMA);

        Flyway.configure()
            .dataSource(jdbcUrl, username, password)
            .schemas(TEST_SCHEMA)
            .load()
            .migrate();

        try (var connection = DriverManager.getConnection(jdbcUrl, username, password);
             var statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            statement.executeUpdate(
                "insert into users (id, email, password_hash, display_name) values "
                    + "('" + OWNER_ID + "', 'vault-owner@example.com', 'test-only', 'Owner'), "
                    + "('" + INVITEE_ID + "', 'vault-invitee@example.com', 'test-only', 'Invitee')");
            statement.executeUpdate(
                "insert into memory_vaults (id, name, status) values "
                    + "('" + VAULT_ID + "', 'Invite Test Vault', 'ACTIVE')");
            statement.executeUpdate(
                "insert into vault_memberships "
                    + "(vault_id, user_id, role, status) values "
                    + "('" + VAULT_ID + "', '" + OWNER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into devices "
                    + "(id, serial_number, name, status, claimed_at, claimed_by) values "
                    + "('" + DEVICE_ID + "', 'INVITE-TEST-0001', 'Invite Test Cam', "
                    + "'ONLINE', now(), '" + OWNER_ID + "')");
            statement.executeUpdate(
                "insert into device_memberships (device_id, user_id, role, status) values "
                    + "('" + DEVICE_ID + "', '" + OWNER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into device_bindings (device_id, vault_id, generation, status) values "
                    + "('" + DEVICE_ID + "', '" + VAULT_ID + "', 1, 'ACTIVE')");
            connection.commit();
        }
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    /** Reproduces POST /api/vaults/{vaultId}/invitations down to the row it returns. */
    @Test
    void insertsAndReadsBackVaultInvitation() {
        UUID invitationId = UUID.randomUUID();
        Instant expiresAt = Instant.now().plus(7, ChronoUnit.DAYS);

        try (var session = sessionFactory().openSession()) {
            InvitationMapper mapper = session.getMapper(InvitationMapper.class);

            assertThat(mapper.activeUserEmailExists("vault-invitee@example.com")).isTrue();
            assertThat(mapper.activeVaultMemberEmailExists(
                VAULT_ID, "vault-invitee@example.com")).isFalse();
            assertThat(mapper.pendingVaultInvitationExists(
                VAULT_ID, "vault-invitee@example.com")).isFalse();
            assertThat(mapper.findFirstActiveDeviceId(VAULT_ID)).contains(DEVICE_ID);

            mapper.insertVaultInvitation(
                invitationId, VAULT_ID, DEVICE_ID, OWNER_ID,
                "vault-invitee@example.com", expiresAt);
            session.commit();

            InvitationRow row = mapper
                .findScopedVaultInvitation(VAULT_ID, invitationId)
                .orElseThrow();

            assertThat(row.id()).isEqualTo(invitationId);
            assertThat(row.vaultId()).isEqualTo(VAULT_ID);
            assertThat(row.vaultName()).isEqualTo("Invite Test Vault");
            assertThat(row.deviceId()).isEqualTo(DEVICE_ID);
            assertThat(row.inviteeEmail()).isEqualTo("vault-invitee@example.com");
            assertThat(row.role()).isEqualTo("MEMBER");
            assertThat(row.status()).isEqualTo("PENDING");

            assertThat(mapper.findVaultInvitations(VAULT_ID))
                .extracting(InvitationRow::id)
                .contains(invitationId);
            assertThat(mapper.findReceivedInvitations("vault-invitee@example.com"))
                .extracting(InvitationRow::id)
                .contains(invitationId);
        }
    }

    private static org.apache.ibatis.session.SqlSessionFactory sessionFactory() {
        var dataSource = new UnpooledDataSource(
            "org.postgresql.Driver", jdbcUrl, username, password);
        var environment = new Environment(
            "integration-test", new JdbcTransactionFactory(), dataSource);
        var configuration = new Configuration(environment);
        configuration.setMapUnderscoreToCamelCase(true);
        // Same registration the application applies, so the scalar uuid reads
        // below fail here whenever they would fail in production.
        new MyBatisConfig().uuidTypeHandlerCustomizer().customize(configuration);
        configuration.addMapper(InvitationMapper.class);
        return new SqlSessionFactoryBuilder().build(configuration);
    }

    private static String requiredEnvironment(String name) {
        var value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " must be set");
        }
        return value;
    }

    private static String withCurrentSchema(String url, String schema) {
        return url + (url.contains("?") ? "&" : "?") + "currentSchema=" + schema;
    }
}
