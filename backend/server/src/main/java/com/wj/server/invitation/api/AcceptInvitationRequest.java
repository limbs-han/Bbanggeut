package com.wj.server.invitation.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record AcceptInvitationRequest(
    @NotBlank @Size(min = 32, max = 2048) String invitationToken
) {
}
