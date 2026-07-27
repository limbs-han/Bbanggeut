package com.wj.server.invitation.api;

import java.net.URI;
import java.util.List;
import java.util.UUID;

import com.wj.server.invitation.application.InvitationService;
import com.wj.server.invitation.application.MembershipRequestService;
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
    private final MembershipRequestService membershipRequestService;

    public InvitationController(
        InvitationService invitationService,
        MembershipRequestService membershipRequestService
    ) {
        this.invitationService = invitationService;
        this.membershipRequestService = membershipRequestService;
    }

    // --- owner side: invite by email, list, withdraw ---

    @PostMapping("/devices/{deviceId}/invitations")
    public ResponseEntity<InvitationResponse> createInvitation(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @Valid @RequestBody CreateInvitationRequest request
    ) {
        return ResponseEntity.status(201)
            .body(invitationService.createInvitation(
                userId(jwt), deviceId, request.email(), request.role(),
                request.membershipRequestToken()));
    }

    @PostMapping("/membership-request-links")
    public ResponseEntity<MembershipRequestLinkResponse> createMembershipRequestLink(
        @AuthenticationPrincipal Jwt jwt
    ) {
        return ResponseEntity.status(201)
            .body(membershipRequestService.create(userId(jwt)));
    }

    @GetMapping("/membership-request-links/{token}")
    public MembershipRequestPreviewResponse previewMembershipRequest(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable String token
    ) {
        return membershipRequestService.preview(userId(jwt), token);
    }

    @GetMapping("/membership-request-links/{token}/open")
    public ResponseEntity<Void> openMembershipRequest(@PathVariable String token) {
        if (!token.matches("[A-Za-z0-9_-]{43}")) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.status(302)
            .location(URI.create("bbanggeut://membership-request/" + token))
            .build();
    }

    @GetMapping("/devices/{deviceId}/invitations")
    public List<InvitationResponse> listDeviceInvitations(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return invitationService.listDeviceInvitations(userId(jwt), deviceId);
    }

    @DeleteMapping("/devices/{deviceId}/invitations/{invitationId}")
    public ResponseEntity<Void> revokeInvitation(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @PathVariable UUID invitationId
    ) {
        invitationService.revokeInvitation(userId(jwt), deviceId, invitationId);
        return ResponseEntity.noContent().build();
    }

    // --- invitee side: inbox, accept, decline ---

    @GetMapping("/invitations")
    public List<InvitationResponse> listMyInvitations(@AuthenticationPrincipal Jwt jwt) {
        return invitationService.listMyInvitations(userId(jwt));
    }

    @PostMapping("/invitations/{invitationId}/accept")
    public DeviceMemberResponse acceptInvitation(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID invitationId
    ) {
        return invitationService.acceptInvitation(userId(jwt), invitationId);
    }

    @PostMapping("/invitations/{invitationId}/decline")
    public ResponseEntity<Void> declineInvitation(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID invitationId
    ) {
        invitationService.declineInvitation(userId(jwt), invitationId);
        return ResponseEntity.noContent().build();
    }

    // --- members ---

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
