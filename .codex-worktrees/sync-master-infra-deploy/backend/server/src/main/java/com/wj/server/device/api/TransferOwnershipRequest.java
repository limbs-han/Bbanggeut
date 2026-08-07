package com.wj.server.device.api;

import java.util.UUID;

import jakarta.validation.constraints.NotNull;

public record TransferOwnershipRequest(@NotNull UUID newOwnerMembershipId) {
}
