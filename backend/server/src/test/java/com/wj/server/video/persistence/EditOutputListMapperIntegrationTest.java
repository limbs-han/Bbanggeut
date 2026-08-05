package com.wj.server.video.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.wj.server.config.MyBatisConfig;
import com.wj.server.video.domain.VideoRow;
import java.sql.DriverManager;
import java.util.UUID;
import org.apache.ibatis.datasource.unpooled.UnpooledDataSource;
import org.apache.ibatis.mapping.Environment;
import org.apache.ibatis.session.Configuration;
import org.apache.ibatis.session.SqlSessionFactory;
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
 * Pins which edit outputs reach the app's 편집 완료 list.
 *
 * <p>Finished edits are uploaded by an OS background job (WorkManager) that has
 * no session, so progress, success and failure are reported only through system
 * notifications. On a device with notifications denied there is nothing else to
 * look at — which made a {@code READY}-only list actively misleading: nothing
 * appeared while the upload ran, and a row that ended in {@code FAILED}
 * disappeared without trace. The list therefore has to carry {@code UPLOADING}
 * and {@code FAILED} rows too, and the app renders their state.
 *
 * <p>What must still be excluded is unchanged: soft-deleted rows, another
 * vault's edits, non-members, and the source videos themselves.
 */
class EditOutputListMapperIntegrationTest {
    private static final String TEST_SCHEMA = "edit_output_list_mapper_test";
    private static final UUID MEMBER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000031");
    private static final UUID OUTSIDER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000032");
    private static final UUID VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000031");
    private static final UUID OTHER_VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000032");
    private static final UUID DEVICE_ID =
        UUID.fromString("30000000-0000-0000-0000-000000000031");
    private static final UUID SOURCE_VIDEO_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000031");
    private static final UUID READY_EDIT_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000032");
    private static final UUID UPLOADING_EDIT_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000033");
    private static final UUID FAILED_EDIT_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000034");
    private static final UUID DELETED_EDIT_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000035");
    private static final UUID OTHER_VAULT_EDIT_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000036");

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
                    + "('" + MEMBER_ID + "', 'edit-member@example.com', 'test-only', 'Member'), "
                    + "('" + OUTSIDER_ID + "', 'edit-outsider@example.com', "
                    + "'test-only', 'Outsider')");
            statement.executeUpdate(
                "insert into memory_vaults (id, name, status) values "
                    + "('" + VAULT_ID + "', 'Edit Test Vault', 'ACTIVE'), "
                    + "('" + OTHER_VAULT_ID + "', 'Other Vault', 'ACTIVE')");
            statement.executeUpdate(
                "insert into vault_memberships (vault_id, user_id, role, status) values "
                    + "('" + VAULT_ID + "', '" + MEMBER_ID + "', 'OWNER', 'ACTIVE'), "
                    + "('" + OTHER_VAULT_ID + "', '" + OUTSIDER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into devices "
                    + "(id, serial_number, name, status, claimed_at, claimed_by) values "
                    + "('" + DEVICE_ID + "', 'EDIT-TEST-0001', 'Edit Test Cam', "
                    + "'ONLINE', now(), '" + MEMBER_ID + "')");
            statement.executeUpdate(
                "insert into device_memberships (device_id, user_id, role, status) values "
                    + "('" + DEVICE_ID + "', '" + MEMBER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into device_bindings (device_id, vault_id, generation, status) values "
                    + "('" + DEVICE_ID + "', '" + VAULT_ID + "', 1, 'ACTIVE')");
            // The source recording is not an edit output and must never be
            // listed here, whatever its status.
            insertVideo(statement, SOURCE_VIDEO_ID, VAULT_ID, "IOT_CAPTURE",
                "원본 웃음", "READY", "01:00", null);
            insertVideo(statement, READY_EDIT_ID, VAULT_ID, "EDIT_OUTPUT",
                "올라간 편집본", "READY", "01:01", null);
            insertVideo(statement, UPLOADING_EDIT_ID, VAULT_ID, "EDIT_OUTPUT",
                "올라가는 중인 편집본", "UPLOADING", "01:02", null);
            insertVideo(statement, FAILED_EDIT_ID, VAULT_ID, "EDIT_OUTPUT",
                "실패한 편집본", "FAILED", "01:03", null);
            insertVideo(statement, DELETED_EDIT_ID, VAULT_ID, "EDIT_OUTPUT",
                "지운 편집본", "READY", "01:04", "now()");
            insertVideo(statement, OTHER_VAULT_EDIT_ID, OTHER_VAULT_ID, "EDIT_OUTPUT",
                "남의 금고 편집본", "READY", "01:05", null);
            connection.commit();
        }
    }

    private static void insertVideo(
        java.sql.Statement statement,
        UUID id,
        UUID vaultId,
        String sourceType,
        String title,
        String status,
        String createdAtClock,
        String deletedAt
    ) throws Exception {
        // event_types is NOT NULL and the list query reads it back through
        // array_to_string, so the fixture has to carry the array — an edit
        // output inherits it from its source recording in production.
        statement.executeUpdate(
            "insert into videos (id, device_id, vault_id, source_type, trigger_type, "
                + "event_types, title, storage_key, status, created_at, deleted_at) values ("
                + "'" + id + "', '" + DEVICE_ID + "', '" + vaultId + "', "
                + "'" + sourceType + "', 'EDIT', array['EDIT']::video_trigger_type[], "
                + "'" + title + "', "
                + "'private/device/" + id + ".mp4', '" + status + "', "
                + "timestamptz '2026-08-04 " + createdAtClock + ":00+09', "
                + (deletedAt == null ? "null" : deletedAt) + ")");
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    /**
     * The list carries in-flight and failed uploads, newest first, so the app
     * can show progress without depending on system notifications.
     */
    @Test
    void listsEditOutputsIncludingPendingAndFailedUploads() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            var edits = mapper.findEditOutputsByVault(MEMBER_ID, VAULT_ID, 50);

            assertThat(edits)
                .extracting(VideoRow::id)
                .containsExactly(FAILED_EDIT_ID, UPLOADING_EDIT_ID, READY_EDIT_ID);
            assertThat(edits)
                .extracting(VideoRow::status)
                .containsExactly("FAILED", "UPLOADING", "READY");
        }
    }

    /** Soft-deleted edits, other vaults' edits, and source recordings stay out. */
    @Test
    void excludesDeletedOtherVaultAndSourceVideos() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            assertThat(mapper.findEditOutputsByVault(MEMBER_ID, VAULT_ID, 50))
                .extracting(VideoRow::id)
                .doesNotContain(DELETED_EDIT_ID, OTHER_VAULT_EDIT_ID, SOURCE_VIDEO_ID);
        }
    }

    /**
     * The arrival sweep reads the same row shape. If this query cannot be
     * mapped, nothing is ever promoted to READY and every finished edit stays
     * stuck at UPLOADING until the stale sweep marks it FAILED — the list would
     * look empty no matter what the app did.
     */
    @Test
    void pendingUploadSweepSeesInFlightEditsOnly() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            assertThat(mapper.findPendingEditUploads(50))
                .extracting(VideoRow::id)
                .containsExactly(UPLOADING_EDIT_ID);
        }
    }

    /** Membership still gates the list — a non-member sees nothing. */
    @Test
    void hidesEditsFromNonMembers() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            assertThat(mapper.findEditOutputsByVault(OUTSIDER_ID, VAULT_ID, 50)).isEmpty();
        }
    }

    private static SqlSessionFactory sessionFactory() {
        var dataSource = new UnpooledDataSource(
            "org.postgresql.Driver", jdbcUrl, username, password);
        var environment = new Environment(
            "integration-test", new JdbcTransactionFactory(), dataSource);
        var configuration = new Configuration(environment);
        configuration.setMapUnderscoreToCamelCase(true);
        new MyBatisConfig().uuidTypeHandlerCustomizer().customize(configuration);
        configuration.addMapper(VideoMapper.class);
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
