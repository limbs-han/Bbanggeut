package com.wj.server.invitation.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.invitation.application.InvitationService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class InvitationController {
    private final InvitationService invitationService;

    public InvitationController(InvitationService invitationService) {
        this.invitationService = invitationService;
    }

    @PostMapping("/devices/{deviceId}/invite-link")
    public ResponseEntity<InviteLinkResponse> createInviteLink(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return ResponseEntity.status(201).body(invitationService.createInviteLink(userId(jwt), deviceId));
    }

    @DeleteMapping("/devices/{deviceId}/invite-link")
    public ResponseEntity<Void> revokeInviteLink(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        invitationService.revokeInviteLink(userId(jwt), deviceId);
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/join-requests")
    public ResponseEntity<JoinRequestResponse> createJoinRequest(
        @AuthenticationPrincipal Jwt jwt,
        @Valid @RequestBody CreateJoinRequestRequest request
    ) {
        return ResponseEntity.status(201).body(invitationService.createJoinRequest(userId(jwt), request));
    }

    @GetMapping("/devices/{deviceId}/join-requests")
    public List<JoinRequestResponse> listPendingJoinRequests(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return invitationService.listPendingJoinRequests(userId(jwt), deviceId);
    }

    @PostMapping("/devices/{deviceId}/join-requests/{requestId}/approve")
    public DeviceMemberResponse approveJoinRequest(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @PathVariable UUID requestId
    ) {
        return invitationService.approveJoinRequest(userId(jwt), deviceId, requestId);
    }

    @PostMapping("/devices/{deviceId}/join-requests/{requestId}/reject")
    public ResponseEntity<Void> rejectJoinRequest(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @PathVariable UUID requestId
    ) {
        invitationService.rejectJoinRequest(userId(jwt), deviceId, requestId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/devices/{deviceId}/members")
    public List<DeviceMemberResponse> listMembers(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return invitationService.listMembers(userId(jwt), deviceId);
    }

    @DeleteMapping("/devices/{deviceId}/members/{membershipId}")
    public ResponseEntity<Void> revokeMember(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @PathVariable UUID membershipId
    ) {
        invitationService.revokeMember(userId(jwt), deviceId, membershipId);
        return ResponseEntity.noContent().build();
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
