package com.wj.server.device.api;

import java.time.Instant;

public record RegistrationCodeResponse(String registrationCode, Instant expiresAt) {
}
