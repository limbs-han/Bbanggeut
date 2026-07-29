package com.wj.server.notification.application;

import java.util.List;

import com.wj.server.notification.domain.PushMessage;

public interface PushGateway {
    List<String> send(List<String> tokens, PushMessage message);
}
