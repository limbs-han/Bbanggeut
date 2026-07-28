package com.wj.server.config;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.actuate.autoconfigure.mail.MailHealthContributorAutoConfiguration;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.mail.MailSenderAutoConfiguration;
import org.springframework.boot.test.context.ConfigDataApplicationContextInitializer;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class MailHealthConfigurationTest {
    private final ApplicationContextRunner contextRunner =
        new ApplicationContextRunner()
            .withInitializer(new ConfigDataApplicationContextInitializer())
            .withConfiguration(AutoConfigurations.of(
                MailSenderAutoConfiguration.class,
                MailHealthContributorAutoConfiguration.class))
            .withPropertyValues("spring.mail.host=localhost");

    @Test
    void optionalSmtpDoesNotMakeOverallHealthDownByDefault() {
        contextRunner.run(context ->
            assertThat(context).doesNotHaveBean("mailHealthContributor"));
    }

    @Test
    void mailHealthCanBeEnabledWhenSmtpIsConfigured() {
        contextRunner
            .withPropertyValues("management.health.mail.enabled=true")
            .run(context ->
                assertThat(context).hasBean("mailHealthContributor"));
    }
}
