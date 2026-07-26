package com.wj.server.iot.event;

import com.wj.server.config.NotificationProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class TouchAlertEmailWorker {
    private static final Logger log = LoggerFactory.getLogger(TouchAlertEmailWorker.class);
    private final DeviceEventMapper mapper;
    private final JavaMailSender mailSender;
    private final NotificationProperties properties;

    public TouchAlertEmailWorker(
        DeviceEventMapper mapper,
        JavaMailSender mailSender,
        NotificationProperties properties
    ) {
        this.mapper = mapper;
        this.mailSender = mailSender;
        this.properties = properties;
    }

    @Scheduled(fixedDelayString = "${app.notification.poll-delay-ms:10000}",
        initialDelayString = "${app.notification.poll-delay-ms:10000}")
    public void sendDue() {
        if (!properties.emailEnabled()) {
            return;
        }
        for (EventEmailNotificationRow row : mapper.findDueEmails(20)) {
            try {
                SimpleMailMessage message = new SimpleMailMessage();
                message.setFrom(properties.from());
                message.setTo(row.recipientEmail());
                message.setSubject("[빵긋] 홈캠 버튼 입력이 감지됐어요");
                message.setText("""
                    %s에서 버튼 입력이 감지됐습니다.

                    감지 시각: %s
                    이벤트 ID: %s

                    빵긋 앱에서 기기 상태와 저장된 영상을 확인해 주세요.
                    """.formatted(row.deviceName(), row.occurredAt(), row.eventId()));
                mailSender.send(message);
                mapper.markEmailSent(row.id());
            } catch (RuntimeException exception) {
                String code = exception.getClass().getSimpleName();
                mapper.markEmailFailed(row.id(), properties.maxAttempts(), code.substring(0, Math.min(120, code.length())));
                log.warn("Touch alert email delivery failed for event {}: {}", row.eventId(), code);
            }
        }
    }
}
