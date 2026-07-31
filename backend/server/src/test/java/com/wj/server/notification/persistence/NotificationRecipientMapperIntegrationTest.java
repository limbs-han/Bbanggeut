package com.wj.server.notification.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.wj.server.config.MyBatisConfig;
import com.wj.server.notification.domain.NotificationRow;
import java.sql.DriverManager;
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
 * Pins the laughter-notification recipient set to the same rule that grants
 * video access: the vault membership behind the device's active binding.
 *
 * <p>Both queries used to resolve recipients through {@code device_memberships},
 * the legacy mirror kept beside {@code vault_memberships}. Only the OWNER row of
 * that mirror is guaranteed — {@code ensure_claimed_device_has_one_owner()}
 * enforces exactly one active OWNER per claimed device and says nothing about
 * MEMBER rows. So a vault MEMBER with no mirror row could open the video yet
 * never be told it existed.
 *
 * <p>This fixture reproduces that shape: the OWNER keeps its mirror row because
 * the trigger demands one, while the MEMBER deliberately has none. The member
 * assertions therefore fail against the old {@code device_memberships} queries.
 */
class NotificationRecipientMapperIntegrationTest {
    private static final String TEST_SCHEMA = "notification_recipient_mapper_test";
    private static final UUID OWNER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000021");
    private static final UUID MEMBER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000022");
    private static final UUID REVOKED_MEMBER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000023");
    private static final UUID VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000021");
    private static final UUID DEVICE_ID =
        UUID.fromString("30000000-0000-0000-0000-000000000021");
    private static final UUID UNBOUND_DEVICE_ID =
        UUID.fromString("30000000-0000-0000-0000-000000000022");
    private static final UUID VIDEO_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000021");

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
                    + "('" + OWNER_ID + "', 'notify-owner@example.com', 'test-only', 'Owner'), "
                    + "('" + MEMBER_ID + "', 'notify-member@example.com', 'test-only', 'Member'), "
                    + "('" + REVOKED_MEMBER_ID + "', 'notify-revoked@example.com', "
                    + "'test-only', 'Revoked')");
            statement.executeUpdate(
                "insert into memory_vaults (id, name, status) values "
                    + "('" + VAULT_ID + "', 'Notify Test Vault', 'ACTIVE')");
            // The revoked member keeps a row so the queries have to filter on
            // status rather than on mere presence.
            statement.executeUpdate(
                "insert into vault_memberships "
                    + "(vault_id, user_id, role, status, revoked_at) values "
                    + "('" + VAULT_ID + "', '" + OWNER_ID + "', 'OWNER', 'ACTIVE', null), "
                    + "('" + VAULT_ID + "', '" + MEMBER_ID + "', 'MEMBER', 'ACTIVE', null), "
                    + "('" + VAULT_ID + "', '" + REVOKED_MEMBER_ID + "', 'MEMBER', "
                    + "'REVOKED', now())");
            statement.executeUpdate(
                "insert into devices "
                    + "(id, serial_number, name, status, claimed_at, claimed_by) values "
                    + "('" + DEVICE_ID + "', 'NOTIFY-TEST-0001', 'Notify Test Cam', "
                    + "'ONLINE', now(), '" + OWNER_ID + "'), "
                    + "('" + UNBOUND_DEVICE_ID + "', 'NOTIFY-TEST-0002', 'Unbound Cam', "
                    + "'UNCLAIMED', null, null)");
            // Only the OWNER mirror row exists, because
            // ensure_claimed_device_has_one_owner() requires exactly one for a
            // claimed device. The MEMBER is left out on purpose: that missing
            // row is the production gap this test guards.
            statement.executeUpdate(
                "insert into device_memberships (device_id, user_id, role, status) values "
                    + "('" + DEVICE_ID + "', '" + OWNER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into device_bindings (device_id, vault_id, generation, status) values "
                    + "('" + DEVICE_ID + "', '" + VAULT_ID + "', 1, 'ACTIVE')");
            // A camera released from the same vault must stop reaching its members.
            statement.executeUpdate(
                "insert into device_bindings "
                    + "(device_id, vault_id, generation, status, ended_at) values "
                    + "('" + UNBOUND_DEVICE_ID + "', '" + VAULT_ID + "', 1, "
                    + "'DISCONNECTED', now())");
            statement.executeUpdate(
                "insert into notification_push_tokens "
                    + "(id, user_id, installation_id, token, platform) values "
                    + "(gen_random_uuid(), '" + OWNER_ID + "', 'owner-install', "
                    + "'token-owner', 'ANDROID'), "
                    + "(gen_random_uuid(), '" + MEMBER_ID + "', 'member-install', "
                    + "'token-member', 'ANDROID'), "
                    + "(gen_random_uuid(), '" + REVOKED_MEMBER_ID + "', 'revoked-install', "
                    + "'token-revoked', 'ANDROID')");
            connection.commit();
        }
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    /** Every active vault member is notified even with no mirror rows present. */
    @Test
    void fansOutToActiveVaultMembersOnly() {
        try (var session = sessionFactory().openSession()) {
            NotificationMapper mapper = session.getMapper(NotificationMapper.class);

            int inserted = mapper.insertLaughterVideoNotifications(
                DEVICE_ID, VIDEO_ID, "웃음 영상");
            session.commit();

            assertThat(inserted).isEqualTo(2);
            assertThat(mapper.findForUser(OWNER_ID, 10))
                .extracting(NotificationRow::resourceId)
                .contains(VIDEO_ID);
            assertThat(mapper.findForUser(MEMBER_ID, 10))
                .extracting(NotificationRow::resourceId)
                .contains(VIDEO_ID);
            assertThat(mapper.findForUser(REVOKED_MEMBER_ID, 10)).isEmpty();
        }
    }

    /** Re-delivery of the same completion must not duplicate the inbox entry. */
    @Test
    void repeatedFanOutStaysIdempotent() {
        UUID videoId = UUID.fromString("40000000-0000-0000-0000-000000000022");
        try (var session = sessionFactory().openSession()) {
            NotificationMapper mapper = session.getMapper(NotificationMapper.class);

            assertThat(mapper.insertLaughterVideoNotifications(DEVICE_ID, videoId, "웃음 영상"))
                .isEqualTo(2);
            assertThat(mapper.insertLaughterVideoNotifications(DEVICE_ID, videoId, "웃음 영상"))
                .isZero();
            session.commit();

            assertThat(mapper.findForUser(MEMBER_ID, 50))
                .extracting(NotificationRow::resourceId)
                .filteredOn(videoId::equals)
                .hasSize(1);
        }
    }

    /** A disconnected camera has no vault behind it, so nobody is notified. */
    @Test
    void skipsDevicesWithoutActiveBinding() {
        UUID videoId = UUID.fromString("40000000-0000-0000-0000-000000000023");
        try (var session = sessionFactory().openSession()) {
            NotificationMapper mapper = session.getMapper(NotificationMapper.class);

            assertThat(mapper.insertLaughterVideoNotifications(
                UNBOUND_DEVICE_ID, videoId, "웃음 영상")).isZero();
            session.commit();
        }
    }

    /** FCM targets must match the inbox recipients, not the legacy mirror. */
    @Test
    void pushTokensFollowVaultMembership() {
        try (var session = sessionFactory().openSession()) {
            PushTokenMapper mapper = session.getMapper(PushTokenMapper.class);

            assertThat(mapper.findActiveTokensByDevice(DEVICE_ID))
                .containsExactly("token-member", "token-owner");
            assertThat(mapper.findActiveTokensByDevice(UNBOUND_DEVICE_ID)).isEmpty();
        }
    }

    private static org.apache.ibatis.session.SqlSessionFactory sessionFactory() {
        var dataSource = new UnpooledDataSource(
            "org.postgresql.Driver", jdbcUrl, username, password);
        var environment = new Environment(
            "integration-test", new JdbcTransactionFactory(), dataSource);
        var configuration = new Configuration(environment);
        configuration.setMapUnderscoreToCamelCase(true);
        new MyBatisConfig().uuidTypeHandlerCustomizer().customize(configuration);
        configuration.addMapper(NotificationMapper.class);
        configuration.addMapper(PushTokenMapper.class);
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
