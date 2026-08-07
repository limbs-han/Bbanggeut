package com.wj.server.invitation.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.util.Base64;
import java.util.HexFormat;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.invitation.api.MembershipRequestLinkResponse;
import com.wj.server.invitation.api.MembershipRequestPreviewResponse;
import com.wj.server.invitation.domain.MembershipRequestRow;
import com.wj.server.invitation.persistence.MembershipRequestMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class MembershipRequestService {
    static final Duration LINK_TTL = Duration.ofHours(24);
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final MembershipRequestMapper mapper;
    private final Clock clock;

    @Autowired
    public MembershipRequestService(MembershipRequestMapper mapper) {
        this(mapper, Clock.systemUTC());
    }

    MembershipRequestService(MembershipRequestMapper mapper, Clock clock) {
        this.mapper = mapper;
        this.clock = clock;
    }

    @Transactional
    public MembershipRequestLinkResponse create(UUID requesterId) {
        mapper.revokeActiveLinks(requesterId);
        String token = newToken();
        var expiresAt = clock.instant().plus(LINK_TTL);
        mapper.insert(UUID.randomUUID(), requesterId, hash(token), expiresAt);
        return new MembershipRequestLinkResponse(token, expiresAt);
    }

    @Transactional(readOnly = true)
    public MembershipRequestPreviewResponse preview(UUID ownerId, String token) {
        if (!mapper.hasActiveOwnerMembership(ownerId)) {
            throw new ApiException(
                HttpStatus.FORBIDDEN, "OWNER_MEMBERSHIP_REQUIRED",
                "기기를 소유한 사용자만 멤버 요청을 확인할 수 있습니다.");
        }
        MembershipRequestRow row = active(token);
        return new MembershipRequestPreviewResponse(
            row.email(), row.displayName(), row.expiresAt());
    }

    public MembershipRequestRow requireForInvitation(String token, String expectedEmail) {
        MembershipRequestRow row = active(token);
        if (!row.email().equalsIgnoreCase(expectedEmail)) {
            throw new ApiException(
                HttpStatus.CONFLICT, "MEMBERSHIP_REQUEST_EMAIL_MISMATCH",
                "멤버 요청 계정과 초대 이메일이 일치하지 않습니다.");
        }
        return row;
    }

    public void consume(
        String token,
        MembershipRequestRow row,
        UUID ownerId,
        UUID invitationId
    ) {
        if (mapper.consume(hash(token), row.requesterId(), ownerId, invitationId) != 1) {
            throw invalidLink();
        }
    }

    private MembershipRequestRow active(String token) {
        if (token == null || token.isBlank() || token.length() > 200) {
            throw invalidLink();
        }
        return mapper.findActive(hash(token)).orElseThrow(this::invalidLink);
    }

    private String newToken() {
        byte[] bytes = new byte[32];
        SECURE_RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String hash(String token) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(token.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private ApiException invalidLink() {
        return new ApiException(
            HttpStatus.NOT_FOUND, "MEMBERSHIP_REQUEST_NOT_FOUND",
            "멤버 요청 링크가 만료되었거나 유효하지 않습니다.");
    }
}
