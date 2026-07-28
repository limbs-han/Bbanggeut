package com.wj.server.notification.domain;

import java.util.Map;

public record PushMessage(String title, String body, Map<String, String> data) {
}
