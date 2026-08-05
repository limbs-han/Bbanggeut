package com.wj.server.laughdraw.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.laughdraw.domain.LaughMemoryRow;
import com.wj.server.laughdraw.domain.LaughReactionCountRow;
import com.wj.server.laughdraw.domain.LaughReactionMemberRow;
import com.wj.server.laughdraw.persistence.LaughDrawMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class LaughDrawServiceTest {
    @Mock
    private LaughDrawMapper mapper;

    private final UUID userId = UUID.randomUUID();
    private final UUID familyId = UUID.randomUUID();

    @Test
    void drawRandomAsksForCandidatesWithinSeventyTwoHours() {
        LaughMemoryRow row = memory(UUID.randomUUID(), "READY", null);
        when(mapper.isFamilyMember(familyId, userId)).thenReturn(true);
        when(mapper.findRandomCandidate(eq(familyId), any(), anyList()))
            .thenReturn(Optional.of(row));
        when(mapper.countReactions(row.id()))
            .thenReturn(List.of(new LaughReactionCountRow("FUNNY", 3)));
        when(mapper.findMyReaction(row.id(), userId)).thenReturn(Optional.of("FUNNY"));

        var result = new LaughDrawService(mapper).drawRandom(userId, familyId, 3, null);

        assertThat(result.hasMemory()).isTrue();
        assertThat(result.memory().video().id()).isEqualTo(row.id());
        assertThat(result.memory().reactionCounts())
            .containsEntry("FUNNY", 3)
            .containsEntry("AGAIN", 0);
        assertThat(result.memory().myReaction()).isEqualTo("FUNNY");

        ArgumentCaptor<Instant> since = ArgumentCaptor.forClass(Instant.class);
        verify(mapper).findRandomCandidate(eq(familyId), since.capture(), anyList());
        assertThat(since.getValue())
            .isCloseTo(Instant.now().minus(Duration.ofHours(72)), within(Duration.ofSeconds(5)));
    }

    @Test
    void drawRandomReturnsEmptyStateInsteadOfNotFound() {
        when(mapper.isFamilyMember(familyId, userId)).thenReturn(true);
        when(mapper.findRandomCandidate(eq(familyId), any(), anyList()))
            .thenReturn(Optional.empty());

        var result = new LaughDrawService(mapper).drawRandom(userId, familyId, null, null);

        assertThat(result.hasMemory()).isFalse();
        assertThat(result.memory()).isNull();
        assertThat(result.message()).contains("최근 3일간");
    }

    @Test
    void drawRandomRetriesWithoutExclusionsWhenEveryCandidateWasSeen() {
        UUID seen = UUID.randomUUID();
        LaughMemoryRow row = memory(seen, "READY", null);
        when(mapper.isFamilyMember(familyId, userId)).thenReturn(true);
        when(mapper.findRandomCandidate(eq(familyId), any(), eq(List.of(seen))))
            .thenReturn(Optional.empty());
        when(mapper.findRandomCandidate(eq(familyId), any(), eq(List.of())))
            .thenReturn(Optional.of(row));
        when(mapper.countReactions(row.id())).thenReturn(List.of());
        when(mapper.findMyReaction(row.id(), userId)).thenReturn(Optional.empty());

        var result = new LaughDrawService(mapper)
            .drawRandom(userId, familyId, 3, List.of(seen, seen));

        assertThat(result.hasMemory()).isTrue();
        assertThat(result.memory().video().id()).isEqualTo(seen);
        assertThat(result.memory().myReaction()).isNull();
    }

    @Test
    void drawRandomRejectsNonMember() {
        when(mapper.isFamilyMember(familyId, userId)).thenReturn(false);

        assertThatThrownBy(
            () -> new LaughDrawService(mapper).drawRandom(userId, familyId, 3, null))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "FAMILY_ACCESS_DENIED");
        verify(mapper, never()).findRandomCandidate(any(), any(), anyList());
    }

    @Test
    void drawRandomRejectsOutOfRangeDays() {
        when(mapper.isFamilyMember(familyId, userId)).thenReturn(true);

        assertThatThrownBy(
            () -> new LaughDrawService(mapper).drawRandom(userId, familyId, 30, null))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
    }

    @Test
    void responseCarriesEveryMemberWhoReacted() {
        UUID memoryId = UUID.randomUUID();
        UUID otherMember = UUID.randomUUID();
        when(mapper.isFamilyMember(familyId, userId)).thenReturn(true);
        when(mapper.findRandomCandidate(eq(familyId), any(), anyList()))
            .thenReturn(Optional.of(memory(memoryId, "READY", null)));
        when(mapper.countReactions(memoryId)).thenReturn(List.of(
            new LaughReactionCountRow("FUNNY", 1),
            new LaughReactionCountRow("GOOD_SAVE", 1)));
        when(mapper.findMyReaction(memoryId, userId)).thenReturn(Optional.of("FUNNY"));
        when(mapper.findReactionMembers(memoryId)).thenReturn(List.of(
            new LaughReactionMemberRow(userId, "엄마", "FUNNY"),
            new LaughReactionMemberRow(otherMember, "아빠", "GOOD_SAVE")));

        var result = new LaughDrawService(mapper).drawRandom(userId, familyId, 3, null);

        var members = result.memory().familyReactions();
        assertThat(members).hasSize(2);
        assertThat(members.get(0).displayName()).isEqualTo("엄마");
        // 본인 반응은 화면에서 다르게 그려야 하므로 표시가 붙는다.
        assertThat(members.get(0).isMe()).isTrue();
        assertThat(members.get(1).displayName()).isEqualTo("아빠");
        assertThat(members.get(1).isMe()).isFalse();
    }

    @Test
    void findMemoryRestoresTodaysDraw() {
        UUID memoryId = UUID.randomUUID();
        when(mapper.findAccessibleMemory(userId, memoryId))
            .thenReturn(Optional.of(memory(memoryId, "READY", null)));
        when(mapper.countReactions(memoryId))
            .thenReturn(List.of(new LaughReactionCountRow("AGAIN", 2)));
        when(mapper.findMyReaction(memoryId, userId)).thenReturn(Optional.of("AGAIN"));

        var result = new LaughDrawService(mapper).findMemory(userId, memoryId);

        assertThat(result.video().id()).isEqualTo(memoryId);
        assertThat(result.reactionCounts()).containsEntry("AGAIN", 2);
        assertThat(result.myReaction()).isEqualTo("AGAIN");
    }

    @Test
    void findMemoryHidesForeignExpiredOrDeletedVideos() {
        UUID foreign = UUID.randomUUID();
        UUID expired = UUID.randomUUID();
        when(mapper.findAccessibleMemory(userId, foreign)).thenReturn(Optional.empty());
        when(mapper.findAccessibleMemory(userId, expired)).thenReturn(
            Optional.of(memory(expired, "READY", Instant.now().minus(Duration.ofHours(1)))));
        var service = new LaughDrawService(mapper);

        assertThatThrownBy(() -> service.findMemory(userId, foreign))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
        assertThatThrownBy(() -> service.findMemory(userId, expired))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }

    @Test
    void reactStoresFirstReactionAndReturnsFreshCounts() {
        UUID memoryId = UUID.randomUUID();
        LaughMemoryRow row = memory(memoryId, "READY", Instant.now().plus(Duration.ofDays(4)));
        when(mapper.findAccessibleMemory(userId, memoryId)).thenReturn(Optional.of(row));
        when(mapper.countReactions(memoryId))
            .thenReturn(List.of(new LaughReactionCountRow("MISS_THIS", 1)));
        when(mapper.findMyReaction(memoryId, userId)).thenReturn(Optional.of("MISS_THIS"));

        var result = new LaughDrawService(mapper).react(userId, memoryId, "MISS_THIS");

        verify(mapper).upsertReaction(memoryId, userId, "MISS_THIS");
        assertThat(result.reactionCounts()).containsEntry("MISS_THIS", 1);
        assertThat(result.myReaction()).isEqualTo("MISS_THIS");
        assertThat(result.expiresAt()).isEqualTo(row.retentionUntil());
    }

    @Test
    void reactChangesTheExistingReactionWithoutCreatingAnother() {
        UUID memoryId = UUID.randomUUID();
        when(mapper.findAccessibleMemory(userId, memoryId))
            .thenReturn(Optional.of(memory(memoryId, "READY", null)));
        when(mapper.countReactions(memoryId))
            .thenReturn(List.of(new LaughReactionCountRow("AGAIN", 1)));
        when(mapper.findMyReaction(memoryId, userId)).thenReturn(Optional.of("AGAIN"));

        var result = new LaughDrawService(mapper).react(userId, memoryId, "again");

        verify(mapper).upsertReaction(memoryId, userId, "AGAIN");
        assertThat(result.reactionCounts()).containsEntry("AGAIN", 1);
    }

    @Test
    void reactRejectsUnknownReactionType() {
        assertThatThrownBy(() -> new LaughDrawService(mapper).react(userId, UUID.randomUUID(), "LOL"))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
        verify(mapper, never()).upsertReaction(any(), any(), any());
    }

    @Test
    void reactRejectsForeignOrMissingMemory() {
        UUID memoryId = UUID.randomUUID();
        when(mapper.findAccessibleMemory(userId, memoryId)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> new LaughDrawService(mapper).react(userId, memoryId, "FUNNY"))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
        verify(mapper, never()).upsertReaction(any(), any(), any());
    }

    @Test
    void reactRejectsExpiredMemory() {
        UUID memoryId = UUID.randomUUID();
        when(mapper.findAccessibleMemory(userId, memoryId)).thenReturn(
            Optional.of(memory(memoryId, "READY", Instant.now().minus(Duration.ofHours(1)))));

        assertThatThrownBy(() -> new LaughDrawService(mapper).react(userId, memoryId, "FUNNY"))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VIDEO_NOT_READY");
        verify(mapper, never()).upsertReaction(any(), any(), any());
    }

    private LaughMemoryRow memory(UUID id, String status, Instant retentionUntil) {
        return new LaughMemoryRow(
            id, UUID.randomUUID(), familyId, "IOT_CAPTURE", "LAUGHTER",
            "아빠의 이상한 춤", "그날 우리 가족은 한참 웃었어요", "video/mp4", 1024L, 12000L,
            Instant.now().minus(Duration.ofHours(5)), Instant.now().minus(Duration.ofHours(5)),
            status, false, retentionUntil, Instant.now().minus(Duration.ofHours(5)), "LAUGHTER");
    }

    private static org.assertj.core.data.TemporalUnitOffset within(Duration duration) {
        return new org.assertj.core.data.TemporalUnitWithinOffset(
            duration.toSeconds(), java.time.temporal.ChronoUnit.SECONDS);
    }
}
