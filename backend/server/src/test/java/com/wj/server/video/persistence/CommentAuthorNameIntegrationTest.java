package com.wj.server.video.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.wj.server.config.MyBatisConfig;
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
 * 방금 쓴 댓글도 이름과 시각이 목록과 같아야 한다.
 *
 * <p>앱은 댓글을 쓴 뒤 서버 응답을 목록에 그대로 붙인다(만화 댓글 시트).
 * 그런데 서비스가 응답을 손으로 조립하면서 작성자 이름을 {@code null}로,
 * 시각을 서버 시계로 채웠다 — 그래서 방금 쓴 댓글만 이름이 기본값 '가족'으로
 * 보이고 시각도 DB와 어긋났다. 목록 질의는 처음부터 users를 조인해 이름을
 * 가져왔으므로 화면을 다시 열면 제대로 나왔고, 그래서 "이름이 바로 안 뜬다"로
 * 나타났다.
 *
 * <p>고친 방식은 저장된 행을 다시 읽어 응답으로 쓰는 것이다. 이 테스트는 두
 * 테이블(만화·영상 댓글)의 단건 조회가 실제로 이름을 채워 오는지, 그리고 다른
 * 영상의 댓글 id로는 읽히지 않는지를 진짜 PostgreSQL에 대고 고정한다.
 */
class CommentAuthorNameIntegrationTest {
    private static final String TEST_SCHEMA = "comment_author_name_test";
    private static final UUID AUTHOR_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000051");
    private static final UUID VAULT_ID =
        UUID.fromString("20000000-0000-0000-0000-000000000051");
    private static final UUID DEVICE_ID =
        UUID.fromString("30000000-0000-0000-0000-000000000051");
    private static final UUID VIDEO_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000051");
    private static final UUID OTHER_VIDEO_ID =
        UUID.fromString("40000000-0000-0000-0000-000000000052");
    private static final UUID COMIC_COMMENT_ID =
        UUID.fromString("50000000-0000-0000-0000-000000000051");
    private static final UUID VIDEO_COMMENT_ID =
        UUID.fromString("50000000-0000-0000-0000-000000000052");

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
                    + "('" + AUTHOR_ID + "', 'comment-author@example.com', "
                    + "'test-only', '할머니')");
            statement.executeUpdate(
                "insert into memory_vaults (id, name, status) values "
                    + "('" + VAULT_ID + "', 'Comment Test Vault', 'ACTIVE')");
            statement.executeUpdate(
                "insert into vault_memberships (vault_id, user_id, role, status) values "
                    + "('" + VAULT_ID + "', '" + AUTHOR_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into devices "
                    + "(id, serial_number, name, status, claimed_at, claimed_by) values "
                    + "('" + DEVICE_ID + "', 'COMMENT-TEST-0001', 'Comment Cam', "
                    + "'ONLINE', now(), '" + AUTHOR_ID + "')");
            statement.executeUpdate(
                "insert into device_memberships (device_id, user_id, role, status) values "
                    + "('" + DEVICE_ID + "', '" + AUTHOR_ID + "', 'OWNER', 'ACTIVE')");
            statement.executeUpdate(
                "insert into device_bindings (device_id, vault_id, generation, status) values "
                    + "('" + DEVICE_ID + "', '" + VAULT_ID + "', 1, 'ACTIVE')");
            for (UUID videoId : new UUID[] {VIDEO_ID, OTHER_VIDEO_ID}) {
                // event_types는 NOT NULL이고 배열이다 — 실제로는 녹화가 채운다.
                statement.executeUpdate(
                    "insert into videos (id, device_id, vault_id, source_type, "
                        + "trigger_type, event_types, title, storage_key, status) values ("
                        + "'" + videoId + "', '" + DEVICE_ID + "', '" + VAULT_ID + "', "
                        + "'IOT_CAPTURE', 'LAUGHTER', "
                        + "array['LAUGHTER']::video_trigger_type[], "
                        + "'웃음', 'private/device/" + videoId + ".mp4', 'READY')");
            }
            statement.executeUpdate(
                "insert into comics (video_id) values ('" + VIDEO_ID + "')");
            statement.executeUpdate(
                "insert into comic_comments (id, video_id, author_id, body) values "
                    + "('" + COMIC_COMMENT_ID + "', '" + VIDEO_ID + "', "
                    + "'" + AUTHOR_ID + "', '만화 잘 봤어')");
            statement.executeUpdate(
                "insert into video_comments (id, video_id, author_id, body) values "
                    + "('" + VIDEO_COMMENT_ID + "', '" + VIDEO_ID + "', "
                    + "'" + AUTHOR_ID + "', '영상 잘 봤어')");
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
    void comicCommentCarriesAuthorNameAndStoredTime() {
        try (var session = sessionFactory(ComicMapper.class).openSession(true)) {
            var row = session.getMapper(ComicMapper.class)
                .findComment(COMIC_COMMENT_ID, VIDEO_ID)
                .orElseThrow();

            assertThat(row.authorName()).isEqualTo("할머니");
            assertThat(row.body()).isEqualTo("만화 잘 봤어");
            assertThat(row.authorId()).isEqualTo(AUTHOR_ID);
            // 시각은 DB가 찍은 값이다 — 서버 시계로 지어내지 않는다.
            assertThat(row.createdAt()).isNotNull();
        }
    }

    @Test
    void videoCommentCarriesAuthorName() {
        try (var session = sessionFactory(VideoCommentMapper.class).openSession(true)) {
            var row = session.getMapper(VideoCommentMapper.class)
                .findComment(VIDEO_COMMENT_ID, VIDEO_ID)
                .orElseThrow();

            assertThat(row.authorName()).isEqualTo("할머니");
            assertThat(row.body()).isEqualTo("영상 잘 봤어");
        }
    }

    /// 다른 영상의 댓글 id를 들고 와도 읽히지 않는다 — 권한 경계가 여기서도 산다.
    @Test
    void commentIsScopedToItsVideo() {
        try (var session = sessionFactory(ComicMapper.class).openSession(true)) {
            assertThat(
                session.getMapper(ComicMapper.class)
                    .findComment(COMIC_COMMENT_ID, OTHER_VIDEO_ID))
                .isEmpty();
        }
        try (var session = sessionFactory(VideoCommentMapper.class).openSession(true)) {
            assertThat(
                session.getMapper(VideoCommentMapper.class)
                    .findComment(VIDEO_COMMENT_ID, OTHER_VIDEO_ID))
                .isEmpty();
        }
    }

    private static SqlSessionFactory sessionFactory(Class<?> mapper) {
        var dataSource = new UnpooledDataSource(
            "org.postgresql.Driver", jdbcUrl, username, password);
        var environment = new Environment(
            "integration-test", new JdbcTransactionFactory(), dataSource);
        var configuration = new Configuration(environment);
        configuration.setMapUnderscoreToCamelCase(true);
        new MyBatisConfig().uuidTypeHandlerCustomizer().customize(configuration);
        configuration.addMapper(mapper);
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
