package com.wj.server.auth.application;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.stereotype.Component;

@Component
public class ConfiguredPasswordResetSender implements PasswordResetSender {
    private static final Logger log =
        LoggerFactory.getLogger(ConfiguredPasswordResetSender.class);

    private final ObjectProvider<JavaMailSender> mailSenderProvider;
    private final String mailHost;
    private final String resetUrl;
    private final String from;

    public ConfiguredPasswordResetSender(
        ObjectProvider<JavaMailSender> mailSenderProvider,
        @Value("${spring.mail.host:}") String mailHost,
        @Value("${app.auth.password-reset-url}") String resetUrl,
        @Value("${app.auth.password-reset-from}") String from
    ) {
        this.mailSenderProvider = mailSenderProvider;
        this.mailHost = mailHost;
        this.resetUrl = resetUrl;
        this.from = from;
    }

    @Override
    public void send(String email, String rawToken) {
        JavaMailSender mailSender = mailSenderProvider.getIfAvailable();
        if (mailHost.isBlank() || mailSender == null) {
            log.warn("Password reset delivery is not configured for {}", email);
            return;
        }
        SimpleMailMessage message = new SimpleMailMessage();
        message.setFrom(from);
        message.setTo(email);
        message.setSubject("[빵긋] 비밀번호 재설정");
        message.setText("""
            아래 링크에서 비밀번호를 재설정해 주세요.
            링크는 30분 동안 한 번만 사용할 수 있습니다.

            %s%s
            """.formatted(
                resetUrl,
                URLEncoder.encode(rawToken, StandardCharsets.UTF_8)));
        mailSender.send(message);
    }
}
