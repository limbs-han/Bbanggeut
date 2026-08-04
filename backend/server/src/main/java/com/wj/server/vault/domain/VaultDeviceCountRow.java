package com.wj.server.vault.domain;

import java.util.UUID;

public record VaultDeviceCountRow(UUID deviceId, String name, long count) {
}
