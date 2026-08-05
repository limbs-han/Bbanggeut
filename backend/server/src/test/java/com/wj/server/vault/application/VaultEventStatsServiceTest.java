package com.wj.server.vault.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.vault.domain.VaultDeviceCountRow;
import com.wj.server.vault.persistence.VaultEventStatsMapper;
import com.wj.server.vault.persistence.VaultMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VaultEventStatsServiceTest {
    private static final Clock FIXED =
        Clock.fixed(Instant.parse("2026-08-04T00:00:00Z"), ZoneOffset.UTC);

    @Mock
    private VaultEventStatsMapper mapper;
    @Mock
    private VaultMapper vaultMapper;

    @Test
    void nonMemberGetsHiddenNotFound() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(vaultMapper.findActiveRole(userId, vaultId)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> new VaultEventStatsService(mapper, vaultMapper, FIXED)
            .get(userId, vaultId, null, null, null, null))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }

    @Test
    void aggregatesAcrossDevicesWithNormalizedTypeFilter() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        UUID deviceA = UUID.randomUUID();
        UUID deviceB = UUID.randomUUID();
        when(vaultMapper.findActiveRole(userId, vaultId)).thenReturn(Optional.of("MEMBER"));
        when(mapper.countEvents(eq(vaultId), any(), any(), eq("LAUGHTER"))).thenReturn(7L);
        when(mapper.countReadyUploads(eq(vaultId), any(), any())).thenReturn(5L);
        when(mapper.countByType(eq(vaultId), any(), any())).thenReturn(List.of());
        when(mapper.countByDevice(eq(vaultId), any(), any(), eq("LAUGHTER"))).thenReturn(List.of(
            new VaultDeviceCountRow(deviceA, "거실", 4L),
            new VaultDeviceCountRow(deviceB, "안방", 3L)));
        when(mapper.countByDay(eq(vaultId), any(), any(), any(), eq("LAUGHTER")))
            .thenReturn(List.of());

        var result = new VaultEventStatsService(mapper, vaultMapper, FIXED)
            .get(userId, vaultId, null, null, null, " laughter ");

        assertThat(result.detectedCount()).isEqualTo(7L);
        assertThat(result.byDevice()).hasSize(2);
        assertThat(result.byDevice().get(0).name()).isEqualTo("거실");
    }

    @Test
    void rangeOverOneYearIsRejected() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(vaultMapper.findActiveRole(userId, vaultId)).thenReturn(Optional.of("OWNER"));

        assertThatThrownBy(() -> new VaultEventStatsService(mapper, vaultMapper, FIXED)
            .get(userId, vaultId,
                LocalDate.of(2025, 1, 1), LocalDate.of(2026, 8, 1), null, null))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
    }
}
