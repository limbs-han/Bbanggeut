package com.wj.server.laughdraw.application;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.laughdraw.api.LaughDrawResponse;
import com.wj.server.laughdraw.api.LaughMemoryResponse;
import com.wj.server.laughdraw.api.LaughReactionMemberResponse;
import com.wj.server.laughdraw.domain.LaughMemoryRow;
import com.wj.server.laughdraw.domain.LaughReactionType;
import com.wj.server.laughdraw.persistence.LaughDrawMapper;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoEventTypes;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 웃음 뽑기: 최근 며칠 사이 저장된 우리 가족 웃음 영상 하나를 무작위로 꺼내 보여 주고
 * 이모지 반응을 받는다.
 *
 * <p>영상 보관 기간은 기기 설정을 따르지만(기본 7일) 뽑기 후보는 최근 3일치만 쓴다 —
 * "요즘 우리 집"을 다시 보는 기능이라서다.
 */
@Service
public class LaughDrawService {
    /** 기본 후보 기간. 3일 = 72시간. */
    public static final int DEFAULT_DAYS = 3;
    /** 뽑기 기간의 상한. 보관 기간(기본 7일)을 넘겨 봐야 후보가 늘지 않는다. */
    public static final int MAX_DAYS = 7;
    /** 한 세션에서 이미 본 영상 수의 상한. 질의 파라미터가 무한히 길어지지 않게 한다. */
    public static final int MAX_EXCLUDE_IDS = 100;

    private static final String EMPTY_MESSAGE_TEMPLATE = "최근 %d일간 저장된 웃음 영상이 없어요.";

    private final LaughDrawMapper mapper;

    public LaughDrawService(LaughDrawMapper mapper) {
        this.mapper = mapper;
    }

    /**
     * 무작위 웃음 영상 한 건.
     *
     * <p>이미 본 영상({@code excludeIds})을 뺐더니 후보가 하나도 남지 않으면 제외를
     * 풀고 한 번 더 고른다. 가족에게 웃음 영상이 한 건뿐일 때 "다른 영상 보기"가
     * 빈 화면으로 떨어지지 않게 하는 장치다.
     */
    @Transactional(readOnly = true)
    public LaughDrawResponse drawRandom(
        UUID userId, UUID familyId, Integer days, List<UUID> excludeIds) {
        requireFamilyMember(userId, familyId);
        int window = normalizeDays(days);
        List<UUID> excluded = normalizeExcludeIds(excludeIds);
        Instant since = Instant.now().minus(Duration.ofDays(window));

        Optional<LaughMemoryRow> picked = mapper.findRandomCandidate(familyId, since, excluded);
        if (picked.isEmpty() && !excluded.isEmpty()) {
            picked = mapper.findRandomCandidate(familyId, since, List.of());
        }
        return picked
            .map(row -> LaughDrawResponse.of(toMemoryResponse(row, userId)))
            .orElseGet(() -> LaughDrawResponse.empty(
                EMPTY_MESSAGE_TEMPLATE.formatted(window)));
    }

    /**
     * 뽑기 결과 한 건을 다시 읽는다.
     *
     * <p>앱이 "오늘 뽑은 영상"을 기기에 적어 두고 다음 진입에서 그 화면을 되살릴 때
     * 쓴다. 저장된 것은 videoId 하나뿐이라 제목·반응 개수·가족 반응은 언제나 서버의
     * 최신 값으로 다시 채운다 — 그동안 가족이 남긴 반응이 화면에 그대로 보이게.
     *
     * <p>이미 지워지거나 만료된 영상이면 404를 준다. 앱은 그때 저장을 버리고
     * 첫 뽑기 화면으로 돌아간다.
     */
    @Transactional(readOnly = true)
    public LaughMemoryResponse findMemory(UUID userId, UUID memoryId) {
        LaughMemoryRow memory = mapper.findAccessibleMemory(userId, memoryId)
            .orElseThrow(() -> notFound("영상을 찾을 수 없습니다."));
        if (!isPlayable(memory)) {
            throw notFound("영상을 찾을 수 없습니다.");
        }
        return toMemoryResponse(memory, userId);
    }

    /**
     * 이모지 반응을 남기거나 바꾼다.
     *
     * <p>같은 사람은 한 영상에 반응 하나만 가진다. 이미 남긴 반응이 있으면 종류만
     * 바뀌고, 같은 것을 다시 눌러도 개수는 늘지 않는다.
     */
    @Transactional
    public LaughMemoryResponse react(UUID userId, UUID memoryId, String reactionType) {
        LaughReactionType reaction = LaughReactionType.from(reactionType);
        if (reaction == null) {
            throw validation("지원하지 않는 reactionType입니다. " + LaughReactionType.names());
        }
        LaughMemoryRow memory = mapper.findAccessibleMemory(userId, memoryId)
            .orElseThrow(() -> notFound("영상을 찾을 수 없습니다."));
        if (!isPlayable(memory)) {
            throw new ApiException(
                HttpStatus.CONFLICT, "VIDEO_NOT_READY", "이미 지워지거나 만료된 영상에는 반응할 수 없어요.");
        }
        mapper.upsertReaction(memoryId, userId, reaction.name());
        return toMemoryResponse(memory, userId);
    }

    private boolean isPlayable(LaughMemoryRow memory) {
        if (!"READY".equals(memory.status())) {
            return false;
        }
        return memory.retentionUntil() == null || memory.retentionUntil().isAfter(Instant.now());
    }

    private void requireFamilyMember(UUID userId, UUID familyId) {
        if (!mapper.isFamilyMember(familyId, userId)) {
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FAMILY_ACCESS_DENIED", "이 가족의 구성원만 이용할 수 있어요.");
        }
    }

    private int normalizeDays(Integer days) {
        if (days == null) {
            return DEFAULT_DAYS;
        }
        if (days < 1 || days > MAX_DAYS) {
            throw validation("days는 1 이상 " + MAX_DAYS + " 이하여야 합니다.");
        }
        return days;
    }

    private List<UUID> normalizeExcludeIds(List<UUID> excludeIds) {
        if (excludeIds == null || excludeIds.isEmpty()) {
            return List.of();
        }
        List<UUID> unique = excludeIds.stream().filter(java.util.Objects::nonNull).distinct().toList();
        return unique.size() > MAX_EXCLUDE_IDS
            ? unique.subList(unique.size() - MAX_EXCLUDE_IDS, unique.size())
            : unique;
    }

    private LaughMemoryResponse toMemoryResponse(LaughMemoryRow row, UUID userId) {
        Map<String, Integer> counts = LaughReactionType.emptyCounts();
        mapper.countReactions(row.id()).forEach(entry -> {
            if (counts.containsKey(entry.reactionType())) {
                counts.put(entry.reactionType(), entry.count());
            }
        });
        return new LaughMemoryResponse(
            toVideoResponse(row),
            row.retentionUntil(),
            counts,
            mapper.findMyReaction(row.id(), userId).orElse(null),
            mapper.findReactionMembers(row.id()).stream()
                .map(member -> new LaughReactionMemberResponse(
                    member.memberId(),
                    member.displayName(),
                    member.reactionType(),
                    member.memberId().equals(userId)))
                .toList());
    }

    private VideoResponse toVideoResponse(LaughMemoryRow row) {
        // VideoResponse에 description이 없다 — 영상 메모 기능이 제거됐다.
        // videos.description 컬럼과 LaughMemoryRow.description은 남아 있지만
        // 응답에는 싣지 않는다.
        return new VideoResponse(
            row.id(), row.deviceId(), row.sourceType(), row.triggerType(), null,
            row.title(), row.contentType(), row.sizeBytes(), null,
            row.durationMs(), row.capturedStartAt(), row.capturedEndAt(), row.status(),
            row.favorite(), null, row.createdAt(),
            VideoEventTypes.fromCsv(row.eventTypesCsv(), row.triggerType()));
    }

    private ApiException notFound(String message) {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", message);
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
