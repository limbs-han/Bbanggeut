package com.wj.server.laughdraw.domain;

import java.util.UUID;

/** 이 영상에 반응을 남긴 가족 구성원 한 명. */
public record LaughReactionMemberRow(
    UUID memberId,
    String displayName,
    String reactionType
) {
}
