package com.wj.server.audit.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.domain.AccessLogRow;
import com.wj.server.audit.persistence.AccessLogMapper;
import com.wj.server.common.api.ApiException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class AccessLogQueryServiceTest {
    @Mock
    private AccessLogMapper mapper;
    private AccessLogCursorCodec codec;
    private AccessLogQueryService service;

    @BeforeEach
    void setUp() {
        codec = new AccessLogCursorCodec();
        service = new AccessLogQueryService(mapper, codec);
    }

    @Test
    void ownerGetsKeysetPage() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        AccessLogRow first = row(2, deviceId, Instant.parse("2026-07-17T10:00:02Z"));
        AccessLogRow second = row(1, deviceId, Instant.parse("2026-07-17T10:00:01Z"));
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.findPage(deviceId, null, null, 2)).thenReturn(List.of(first, second));

        var page = service.list(userId, deviceId, null, 1);

        assertThat(page.items()).hasSize(1);
        assertThat(page.hasNext()).isTrue();
        assertThat(codec.decode(page.nextCursor()).id()).isEqualTo(2L);
    }

    @Test
    void editorCannotReadAuditLogs() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.list(userId, deviceId, null, 20))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(mapper, never()).findPage(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyInt());
    }

    @Test
    void vaultOwnerReadsAuditLogsWithoutAnyConnectedDevice() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        AccessLogRow only = row(7, null, Instant.parse("2026-07-30T10:00:00Z"));
        when(mapper.findActiveVaultRole(userId, vaultId)).thenReturn(Optional.of("OWNER"));
        when(mapper.findVaultPage(vaultId, null, null, 21)).thenReturn(List.of(only));

        var page = service.listForVault(userId, vaultId, null, 20);

        assertThat(page.items()).hasSize(1);
        assertThat(page.hasNext()).isFalse();
        assertThat(page.nextCursor()).isNull();
    }

    @Test
    void vaultMemberCannotReadAuditLogs() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(mapper.findActiveVaultRole(userId, vaultId)).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.listForVault(userId, vaultId, null, 20))
            .isInstanceOf(ApiException.class)
            .satisfies(exception ->
                assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(mapper, never()).findVaultPage(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyInt());
    }

    private AccessLogRow row(long id, UUID deviceId, Instant createdAt) {
        return new AccessLogRow(
            id, deviceId, UUID.randomUUID(), null, "VIDEO_VIEW", "VIDEO", UUID.randomUUID(),
            "SUCCESS", null, createdAt);
    }
}
