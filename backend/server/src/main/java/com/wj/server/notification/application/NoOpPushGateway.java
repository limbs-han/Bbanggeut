package com.wj.server.notification.application;

import java.util.List;

import com.wj.server.notification.domain.PushMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    name = "app.push.enabled",
    havingValue = "false",
    matchIfMissing = true
)
public class NoOpPushGateway implements PushGateway {
    private static final Logger log = LoggerFactory.getLogger(NoOpPushGateway.class);

    @Override
    public List<String> send(List<String> tokens, PushMessage message) {
        // 완전 무음이면 "푸시가 왜 안 오지"를 로그로도 못 찾는다 — 알림이
        // 만들어졌는데 FCM이 꺼져 있어 버려졌음을 한 줄 남긴다.
        log.info(
            "Push disabled (FCM_ENABLED=false) — dropping type={} for {} token(s)",
            message.data().get("type"), tokens.size());
        return List.of();
    }
}
