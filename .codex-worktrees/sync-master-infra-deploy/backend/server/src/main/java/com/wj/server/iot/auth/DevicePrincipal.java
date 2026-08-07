package com.wj.server.iot.auth;

import java.util.UUID;

public record DevicePrincipal(UUID deviceId, String keyId, String purpose) {
}
