package com.wj.server.migration;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URISyntaxException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import org.junit.jupiter.api.Test;

/**
 * {@link FlywayMigrationIntegrationTest#LATEST_SCHEMA_VERSION}이 실제 마이그레이션
 * 파일을 따라가는지 **DB 없이** 확인한다.
 *
 * <p><b>왜 따로 있는가</b>: 그 번호를 검사하는 단정은 Testcontainers 통합
 * 테스트 안에 있고, 그 클래스는 Docker나 {@code TEST_POSTGRES_*}가 없으면
 * {@code assumeTrue}로 건너뛴다. 그래서 로컬 Docker가 꺼진 개발기에서는 새
 * 마이그레이션을 넣고 번호를 빠뜨려도 초록으로 보이고, CI에 가서야 터진다 —
 * 실제로 V48을 그렇게 통과시켜 master 빌드를 깼다.
 *
 * <p>이 테스트는 파일만 읽으므로 어디서든 돈다. 실패하면 고칠 곳은 하나다:
 * {@code LATEST_SCHEMA_VERSION}을 방금 추가한 마이그레이션 번호로 올린다.
 */
class SchemaVersionGuardTest {
    /** {@code V47__device_detection_switch.sql} → 47 */
    private static final Pattern VERSIONED_MIGRATION =
        Pattern.compile("^V(\\d+)__.+\\.sql$");

    @Test
    void pinnedSchemaVersionMatchesTheLastMigrationOnDisk() {
        var migrations = migrationDirectory();
        try (Stream<Path> files = Files.list(migrations)) {
            var latest = files
                .map(path -> path.getFileName().toString())
                .map(VERSIONED_MIGRATION::matcher)
                .filter(java.util.regex.Matcher::matches)
                .map(matcher -> Integer.valueOf(matcher.group(1)))
                .max(Comparator.naturalOrder())
                .orElseThrow(() -> new IllegalStateException(
                    "마이그레이션 파일이 없습니다: " + migrations));

            assertThat(FlywayMigrationIntegrationTest.LATEST_SCHEMA_VERSION)
                .as("마이그레이션을 추가했으면 FlywayMigrationIntegrationTest."
                    + "LATEST_SCHEMA_VERSION도 함께 올려야 한다")
                .isEqualTo(String.valueOf(latest));
        } catch (IOException failure) {
            throw new UncheckedIOException(failure);
        }
    }

    /**
     * 클래스패스에서 찾는다 — 테스트의 작업 디렉터리에 기대지 않는다. Gradle이
     * 리소스를 실제 디렉터리로 풀어 두므로 목록을 읽을 수 있다.
     */
    private static Path migrationDirectory() {
        var resource = SchemaVersionGuardTest.class.getClassLoader()
            .getResource("db/migration");
        if (resource == null) {
            throw new IllegalStateException("클래스패스에 db/migration이 없습니다.");
        }
        try {
            return Path.of(resource.toURI());
        } catch (URISyntaxException failure) {
            throw new IllegalStateException(failure);
        }
    }
}
