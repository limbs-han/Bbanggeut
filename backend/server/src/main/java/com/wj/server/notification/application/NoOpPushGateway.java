package com.wj.server.notification.application;

import java.util.List;

import com.wj.server.notification.domain.PushMessage;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    name = "app.push.enabled",
    havingValue = "false",
    matchIfMissing = true
)
public class NoOpPushGateway implements PushGateway {
    @Override
    public List<String> send(List<String> tokens, PushMessage message) {
        return List.of();
    }
}
