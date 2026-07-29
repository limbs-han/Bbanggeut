package com.wj.server.common.ratelimit;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.data.redis.RedisAutoConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.data.redis.core.StringRedisTemplate;

/**
 * The limiter depends on a template supplied by Redis auto configuration. A
 * missing or renamed starter would otherwise only surface when the application
 * starts, so the wiring is checked here without needing a running Redis.
 */
class SlidingWindowRateLimiterWiringTest {

    @Test
    void takesItsTemplateFromRedisAutoConfiguration() {
        new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(RedisAutoConfiguration.class))
            .withUserConfiguration(SlidingWindowRateLimiter.class)
            .withPropertyValues("spring.data.redis.host=localhost", "spring.data.redis.port=6379")
            .run(context -> {
                assertThat(context).hasNotFailed();
                assertThat(context).hasSingleBean(StringRedisTemplate.class);
                assertThat(context).hasSingleBean(SlidingWindowRateLimiter.class);
            });
    }
}
