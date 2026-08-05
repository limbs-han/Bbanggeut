package com.wj.server.laughdraw.api;

import java.util.UUID;

/**
 * 가족 반응 한 줄. 반응을 남긴 구성원만 담긴다.
 *
 * <p>프로필 사진은 기기에만 저장되는 값이라 서버가 알지 못한다. 앱은 이름의 첫
 * 글자로 원형 아바타를 그리고, 본인 것만 기기에 저장된 아바타로 바꿔 그린다.
 */
public record LaughReactionMemberResponse(
    UUID memberId,
    String displayName,
    String reactionType,
    boolean isMe
) {
}
