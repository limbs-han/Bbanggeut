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
 * 홈의 "최근 저장된 추억"이 고르는 한 건을 못박는다.
 *
 * <p>예전 정렬은 {@code is_favorite DESC}를 맨 앞에 두었다. 그래서 즐겨찾기를
 * 한 번 누르면 그 영상이 카드에 붙어 버리고, 그 뒤에 저장된 영상은 아무리
 * 새것이어도 홈에 올라오지 못했다 — 실사용 기기에서 7월 31일 즐겨찾기 영상이
 * 오늘 들어온 영상들을 가린 채 며칠을 버텼다. 정렬 한 줄이 되돌아가면 같은
 * 증상이 조용히 재발하므로, 즐겨찾기와 최신을 갈라 놓은 데이터로 고정한다.
 */
class LatestHighlightMapperIntegrationTest {
    private static final String TEST_SCHEMA = "latest_highlight_mapper_test";
    private static final UUID MEMBER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000041");
    private static final UUID OUTSIDER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000042");
    private static final UUID VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000041");
    private static final UUID DEVICE_ID =
        UUID.fromString("30000000-0000-0000-0000-000000000041");
    /** 오래됐지만 즐겨찾기다 — 예전 정렬이 붙잡고 있던 그 영상. */
    private static final UUID OLD_FAVORITE_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000041");
    /** 가장 최근에 저장됐고 즐겨찾기가 아니다 — 홈이 보여 줘야 하는 영상. */
    private static final UUID NEWEST_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000042");
    private static final UUID MIDDLE_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000043");
    /** 가장 최근이지만 아직 올라가는 중 — 홈에 나오면 재생할 것이 없다. */
    private static final UUID UPLOADING_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000044");

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
                    + "('" + MEMBER_ID + "', 'home-member@example.com', 'test-only', 'Member'), "
                    + "('" + OUTSIDER_ID + "', 'home-outsider@example.com', "
                    + "'test-only', 'Outsider')");
            statement.executeUpdate(
                "insert into memory_vaults (id, name, status) values "
                    + "('" + VAULT_ID + "', 'Home Test Vault', 'ACTIVE')");
            statement.executeUpdate(
                "insert into vault_memberships (vault_id, user_id, role, status) values "
                    + "('" + VAULT_ID + "', '" + MEMBER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into devices "
                    + "(id, serial_number, name, status, claimed_at, claimed_by) values "
                    + "('" + DEVICE_ID + "', 'HOME-TEST-0001', 'Home Test Cam', "
                    + "'ONLINE', now(), '" + MEMBER_ID + "')");
            statement.executeUpdate(
                "insert into device_memberships (device_id, user_id, role, status) values "
                    + "('" + DEVICE_ID + "', '" + MEMBER_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into device_bindings (device_id, vault_id, generation, status) values "
                    + "('" + DEVICE_ID + "', '" + VAULT_ID + "', 1, 'ACTIVE')");
            insertVideo(statement, OLD_FAVORITE_ID, "즐겨찾기한 옛 웃음",
                "READY", "2026-07-31 08:38:50+09", true);
            insertVideo(statement, MIDDLE_ID, "중간 웃음",
                "READY", "2026-08-06 05:48:37+09", false);
            insertVideo(statement, NEWEST_ID, "가장 최근 웃음",
                "READY", "2026-08-06 06:38:07+09", false);
            insertVideo(statement, UPLOADING_ID, "아직 올라가는 중",
                "UPLOADING", "2026-08-06 06:40:00+09", false);
            connection.commit();
        }
    }

    private static void insertVideo(
        java.sql.Statement statement,
        UUID id,
        String title,
        String status,
        String capturedStartAt,
        boolean favorite
    ) throws Exception {
        statement.executeUpdate(
            "insert into videos (id, device_id, vault_id, source_type, trigger_type, "
                + "event_types, title, storage_key, status, captured_start_at, "
                + "is_favorite) values ("
                + "'" + id + "', '" + DEVICE_ID + "', '" + VAULT_ID + "', "
                + "'IOT_CAPTURE', 'LAUGHTER', array['LAUGHTER']::video_trigger_type[], "
                + "'" + title + "', 'private/device/" + id + ".mp4', '" + status + "', "
                + "timestamptz '" + capturedStartAt + "', " + favorite + ")");
    }

    @AfterAll
    static void stopPostgres() {
        if (postgres != null) {
            postgres.stop();
        }
    }

    /** 즐겨찾기가 아무리 있어도 가장 최근에 저장된 것이 나온다. */
    @Test
    void picksTheNewestReadyVideoRegardlessOfFavorites() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            assertThat(mapper.findLatestHighlight(MEMBER_ID, DEVICE_ID))
                .get()
                .extracting(VideoRow::id)
                .isEqualTo(NEWEST_ID);
        }
    }

    /**
     * 올라가는 중인 영상은 고르지 않는다. 홈 카드는 눌러서 바로 재생하는
     * 자리라, 아직 객체가 없는 행을 보여 주면 열자마자 실패한다.
     */
    @Test
    void skipsVideosThatAreNotReadyYet() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            assertThat(mapper.findLatestHighlight(MEMBER_ID, DEVICE_ID))
                .get()
                .extracting(VideoRow::id)
                .isNotEqualTo(UPLOADING_ID);
        }
    }

    /** 금고 구성원이 아니면 아무것도 보이지 않는다. */
    @Test
    void hidesEverythingFromNonMembers() {
        try (var session = sessionFactory().openSession()) {
            VideoMapper mapper = session.getMapper(VideoMapper.class);

            assertThat(mapper.findLatestHighlight(OUTSIDER_ID, DEVICE_ID)).isEmpty();
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
