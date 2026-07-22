package com.wj.server.invitation.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record CreateJoinRequestRequest(
    @NotBlank @Size(min = 16, max = 100) String inviteToken
) {
}
