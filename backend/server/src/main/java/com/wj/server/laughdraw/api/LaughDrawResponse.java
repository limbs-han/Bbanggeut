package com.wj.server.laughdraw.api;

/**
 * 웃음 뽑기 결과.
 *
 * <p>꺼낼 영상이 없는 것은 오류가 아니라 정상 상태라서 404가 아니라 200 + 빈 결과로
 * 돌려준다. 앱은 {@code hasMemory}만 보고 결과 화면과 빈 화면을 가른다.
 */
public record LaughDrawResponse(
    boolean hasMemory,
    LaughMemoryResponse memory,
    String message
) {
    public static LaughDrawResponse of(LaughMemoryResponse memory) {
        return new LaughDrawResponse(true, memory, null);
    }

    public static LaughDrawResponse empty(String message) {
        return new LaughDrawResponse(false, null, message);
    }
}
