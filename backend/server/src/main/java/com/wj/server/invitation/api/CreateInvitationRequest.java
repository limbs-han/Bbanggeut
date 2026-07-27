package com.wj.server.invitation.api;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

public record CreateInvitationRequest(
    @NotBlank @Email @Size(max = 320) String email,
    @NotBlank @Pattern(regexp = "EDITOR|VIEWER") String role,
    @Size(max = 200) String membershipRequestToken
) {
}
