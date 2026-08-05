package com.wj.server.place.api;

import java.util.List;
import java.util.UUID;

import jakarta.validation.constraints.NotNull;

/** 부른 사람만의 기기 순서. */
public record UpdateDeviceOrderRequest(@NotNull List<UUID> deviceIds) {
}
