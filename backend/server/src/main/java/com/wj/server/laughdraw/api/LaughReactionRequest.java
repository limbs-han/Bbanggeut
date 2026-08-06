package com.wj.server.laughdraw.api;

import jakarta.validation.constraints.NotBlank;

/**
 * 이모지 반응 요청.
 *
 * <p>누가 남긴 반응인지는 로그인 사용자로 정하므로 memberId는 받지 않는다.
 */
public record LaughReactionRequest(@NotBlank String reactionType) {
}
