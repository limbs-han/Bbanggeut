package com.wj.server.auth.persistence;

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
 * 프로필 수정 SQL을 실제 PostgreSQL에 대고 고정한다.
 *
 * <p>앱의 프로필 수정은 {@code PATCH /api/auth/me} 하나에 달려 있는데, 그 매핑이
 * 아예 없어서 운영에서 모든 요청이 500(Request method 'PATCH' is not supported)으로
 * 떨어졌다. 서비스 계층은 목으로 검증할 수 있지만 정작 틀리기 쉬운 곳은 SQL이다 —
 * 목을 쓰는 단위 테스트는 컬럼 이름이 틀려도 통과한다. 그래서 여기서는 진짜 DB에
 * 대고 확인한다.
 *
 * <p>세 가지를 고정한다. 이름이 실제로 바뀌는지, 탈퇴한 계정({@code deleted_at})은
 * 건드리지 않는지, 그리고 {@code updated_at}이 함께 올라가는지.
 */
class AuthMapperProfileIntegrationTest {
    private static final String TEST_SCHEMA = "auth_mapper_profile_test";
    private static final UUID ACTIVE_USER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000041");
    private static final UUID DELETED_USER_ID =
        UUID.fromString("10000000-0000-0000-0000-000000000042");

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
                    + "('" + ACTIVE_USER_ID + "', 'profile-active@example.com', "
                    + "'test-only', '이전 이름')");
            // ck_users_deleted_status: deleted_at이 있으면 status는 WITHDRAWN이어야 한다.
            statement.executeUpdate(
                "insert into users "
                    + "(id, email, password_hash, display_name, status, deleted_at) values "
                    + "('" + DELETED_USER_ID + "', 'profile-deleted@example.com', "
                    + "'test-only', '떠난 사람', 'WITHDRAWN', now())");
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
    void updateDisplayNameRenamesActiveUserAndTouchesUpdatedAt() throws Exception {
        try (var session = sessionFactory().openSession(true)) {
            AuthMapper mapper = session.getMapper(AuthMapper.class);

            assertThat(mapper.updateDisplayName(ACTIVE_USER_ID, "새 이름")).isEqualTo(1);

            assertThat(mapper.findUserById(ACTIVE_USER_ID))
                .get()
                .extracting("displayName")
                .isEqualTo("새 이름");
        }
        try (var connection = DriverManager.getConnection(jdbcUrl, username, password);
             var statement = connection.prepareStatement(
                 "select updated_at > created_at from users where id = ?")) {
            statement.setObject(1, ACTIVE_USER_ID);
            try (var rows = statement.executeQuery()) {
                rows.next();
                assertThat(rows.getBoolean(1)).isTrue();
            }
        }
    }

    @Test
    void updateDisplayNameLeavesWithdrawnAccountUntouched() {
        try (var session = sessionFactory().openSession(true)) {
            AuthMapper mapper = session.getMapper(AuthMapper.class);

            // 탈퇴 계정은 조회에서도 빠지므로 서비스가 404를 준다. SQL도 같은
            // 규칙이어야 한다 — 안 그러면 지운 계정의 이름이 조용히 바뀐다.
            assertThat(mapper.updateDisplayName(DELETED_USER_ID, "되살아난 이름"))
                .isZero();
            assertThat(mapper.findUserById(DELETED_USER_ID)).isEmpty();
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
        configuration.addMapper(AuthMapper.class);
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
