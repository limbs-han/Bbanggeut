package com.wj.server.invitation.api;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record CreateInvitationRequest(
    @NotBlank @Email @Size(max = 320) String email,
    @Size(max = 200) String membershipRequestToken
) {
}
