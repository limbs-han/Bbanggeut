package com.wj.server.laughdraw.domain;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 웃음 뽑기에서 남길 수 있는 이모지 반응.
 *
 * <p>화면 문구와 이모지는 프런트가 들고 있고, 서버는 종류와 개수만 다룬다.
 */
public enum LaughReactionType {
    FUNNY,
    MISS_THIS,
    GOOD_SAVE,
    EMBARRASSING,
    AGAIN;

    /** 이름으로 찾는다. 알 수 없는 값이면 null — 400/422 판단은 서비스가 한다. */
    public static LaughReactionType from(String value) {
        if (value == null) {
            return null;
        }
        for (LaughReactionType type : values()) {
            if (type.name().equals(value.trim().toUpperCase())) {
                return type;
            }
        }
        return null;
    }

    /**
     * 반응이 하나도 없어도 응답의 키가 사라지지 않도록 모든 종류를 0으로 채운 지도.
     *
     * <p>프런트가 `reactionCounts['AGAIN']`을 그대로 읽어 그리기 때문에 없는 키가
     * 생기면 화면에서 개수가 비어 보인다.
     */
    public static Map<String, Integer> emptyCounts() {
        Map<String, Integer> counts = new LinkedHashMap<>();
        for (LaughReactionType type : values()) {
            counts.put(type.name(), 0);
        }
        return counts;
    }

    public static List<String> names() {
        return List.of(
            FUNNY.name(), MISS_THIS.name(), GOOD_SAVE.name(),
            EMBARRASSING.name(), AGAIN.name());
    }
}
