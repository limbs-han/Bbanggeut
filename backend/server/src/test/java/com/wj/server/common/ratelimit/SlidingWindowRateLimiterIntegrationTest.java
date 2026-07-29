package com.wj.server.common.ratelimit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceClientConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * Exercises the limiter against a real Redis, because the property under test
 * is atomicity between the count and the record. A mocked client cannot show
 * whether concurrent callers observe each other.
 */
class SlidingWindowRateLimiterIntegrationTest {
    private static final int LIMIT = 5;

    private static GenericContainer<?> redis;
    private static LettuceConnectionFactory connectionFactory;
    private static SlidingWindowRateLimiter limiter;

    @BeforeAll
    static void startRedis() {
        String externalHost = System.getenv("TEST_REDIS_HOST");
        if (externalHost != null && !externalHost.isBlank()) {
            connectionFactory = connectionFactory(
                externalHost, Integer.parseInt(requiredEnvironment("TEST_REDIS_PORT")));
            limiter = new SlidingWindowRateLimiter(template(connectionFactory));
            return;
        }

        assumeTrue(
            dockerAvailable(),
            "Docker 또는 TEST_REDIS_* 환경이 없어 Redis 통합 테스트를 건너뜁니다.");

        redis = new GenericContainer<>(DockerImageName.parse("redis:7-alpine")).withExposedPorts(6379);
        redis.start();
        connectionFactory = connectionFactory(redis.getHost(), redis.getMappedPort(6379));
        limiter = new SlidingWindowRateLimiter(template(connectionFactory));
    }

    /**
     * Probing can throw rather than answer when the local Docker API is too new
     * for the bundled client, which should skip the case instead of failing it.
     */
    private static boolean dockerAvailable() {
        try {
            return DockerClientFactory.instance().isDockerAvailable();
        } catch (RuntimeException exception) {
            return false;
        }
    }

    private static String requiredEnvironment(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " 환경 변수가 필요합니다.");
        }
        return value;
    }

    @AfterAll
    static void stopRedis() {
        if (connectionFactory != null) {
            connectionFactory.destroy();
        }
        if (redis != null) {
            redis.stop();
        }
    }

    /**
     * The regression this class exists for. Sequential callers were always
     * limited correctly; simultaneous ones all read the same pre-limit count
     * and passed together, which is the traffic an attacker actually sends.
     */
    @Test
    void admitsExactlyTheLimitWhenFiftyCallersArriveAtOnce() throws Exception {
        String identity = key("identity");
        String address = key("address");
        int callers = 50;
        AtomicInteger admitted = new AtomicInteger();
        CountDownLatch ready = new CountDownLatch(callers);
        CountDownLatch start = new CountDownLatch(1);

        ExecutorService pool = Executors.newFixedThreadPool(callers);
        try {
            List<Future<?>> futures = new ArrayList<>();
            for (int i = 0; i < callers; i++) {
                futures.add(pool.submit(() -> {
                    ready.countDown();
                    start.await();
                    if (limiter.tryAcquire(identity, address, Duration.ofSeconds(30), LIMIT)) {
                        admitted.incrementAndGet();
                    }
                    return null;
                }));
            }
            assertThat(ready.await(10, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            for (Future<?> future : futures) {
                future.get(10, TimeUnit.SECONDS);
            }
        } finally {
            pool.shutdownNow();
        }

        assertThat(admitted.get()).isEqualTo(LIMIT);
    }

    @Test
    void refusesFurtherAttemptsOnceTheIdentityBudgetIsSpent() {
        String identity = key("identity");
        for (int i = 0; i < LIMIT; i++) {
            // A different address each time: the identity budget alone must stop this.
            assertThat(limiter.tryAcquire(identity, key("address"), Duration.ofSeconds(30), LIMIT))
                .isTrue();
        }

        assertThat(limiter.tryAcquire(identity, key("address"), Duration.ofSeconds(30), LIMIT))
            .isFalse();
    }

    @Test
    void refusesFurtherAttemptsOnceTheAddressBudgetIsSpent() {
        String address = key("address");
        for (int i = 0; i < LIMIT; i++) {
            // A different identity each time: guessing many accounts from one
            // address has to be limited too.
            assertThat(limiter.tryAcquire(key("identity"), address, Duration.ofSeconds(30), LIMIT))
                .isTrue();
        }

        assertThat(limiter.tryAcquire(key("identity"), address, Duration.ofSeconds(30), LIMIT))
            .isFalse();
    }

    /**
     * A fixed window would free the whole budget at one shared instant, letting
     * twice the limit through across the boundary. Entries have to expire
     * individually.
     */
    @Test
    void freesBudgetGraduallyAsIndividualEntriesAgeOut() throws Exception {
        String identity = key("identity");
        String address = key("address");
        Duration window = Duration.ofMillis(600);

        assertThat(limiter.tryAcquire(identity, address, window, 2)).isTrue();
        Thread.sleep(400);
        assertThat(limiter.tryAcquire(identity, address, window, 2)).isTrue();
        assertThat(limiter.tryAcquire(identity, address, window, 2)).isFalse();

        // Only the first entry has aged out by now, so exactly one slot returns.
        Thread.sleep(300);
        assertThat(limiter.tryAcquire(identity, address, window, 2)).isTrue();
        assertThat(limiter.tryAcquire(identity, address, window, 2)).isFalse();
    }

    @Test
    void resetReleasesTheIdentityBudgetButLeavesTheAddressBudget() {
        String identity = key("identity");
        String address = key("address");
        for (int i = 0; i < LIMIT; i++) {
            assertThat(limiter.tryAcquire(identity, address, Duration.ofSeconds(30), LIMIT)).isTrue();
        }

        limiter.reset(identity);

        // The address bucket still holds every attempt recorded above.
        assertThat(limiter.tryAcquire(key("identity"), address, Duration.ofSeconds(30), LIMIT))
            .isFalse();
        assertThat(limiter.tryAcquire(identity, key("address"), Duration.ofSeconds(30), LIMIT))
            .isTrue();
    }

    /**
     * Refusing every sign-in during a Redis outage would turn a degraded
     * limiter into a total outage, so the attempt is allowed and logged.
     */
    @Test
    void allowsTheAttemptWhenRedisCannotBeReached() {
        LettuceConnectionFactory unreachable = connectionFactory("127.0.0.1", 6399);
        try {
            SlidingWindowRateLimiter degraded = new SlidingWindowRateLimiter(template(unreachable));

            for (int i = 0; i < LIMIT + 3; i++) {
                assertThat(degraded.tryAcquire(key("identity"), key("address"), Duration.ofSeconds(30), LIMIT))
                    .isTrue();
            }
        } finally {
            unreachable.destroy();
        }
    }

    private static LettuceConnectionFactory connectionFactory(String host, int port) {
        LettuceClientConfiguration clientConfiguration = LettuceClientConfiguration.builder()
            .commandTimeout(Duration.ofMillis(500))
            .shutdownTimeout(Duration.ZERO)
            .build();
        LettuceConnectionFactory factory = new LettuceConnectionFactory(
            new RedisStandaloneConfiguration(host, port), clientConfiguration);
        factory.afterPropertiesSet();
        return factory;
    }

    private static StringRedisTemplate template(LettuceConnectionFactory factory) {
        StringRedisTemplate template = new StringRedisTemplate(factory);
        template.afterPropertiesSet();
        return template;
    }

    /** Fresh key per use so the cases stay independent of each other. */
    private static String key(String kind) {
        return "test:" + kind + ":" + UUID.randomUUID();
    }
}
