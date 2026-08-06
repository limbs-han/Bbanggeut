package com.wj.server.video.domain;

import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

public final class VideoEventTypes {
    private static final List<String> PRESENTATION_ORDER = List.of(
        "LAUGHTER", "CLAP", "WAKE_WORD", "TOUCH", "MANUAL", "USER_UPLOAD", "EDIT");
    private static final Set<String> ALLOWED_TYPES = Set.copyOf(PRESENTATION_ORDER);

    /**
     * 기기가 스스로 잡아서 담은 유형. 나머지(MANUAL·USER_UPLOAD·EDIT)는 사람이
     * 직접 시작한 것이라 "도착했다"고 알릴 대상이 아니다 — 누른 사람은 이미
     * 알고 있다.
     */
    private static final Set<String> DETECTION_TYPES =
        Set.of("LAUGHTER", "CLAP", "WAKE_WORD", "TOUCH");

    /**
     * 감지 유형별 알림 제목. 예전에는 LAUGHTER만 알림을 보냈고 나머지는 영상이
     * 저장돼도 아무 말이 없었다 — 박수로 잡힌 영상 세 건이 연달아 들어왔는데
     * 알림 행조차 만들어지지 않은 것이 실사용에서 드러났다. 유형마다 제목을
     * 달리 두는 것은 알림함에서 무엇 때문에 담긴 영상인지 한 줄로 갈라 보이게
     * 하려는 것이다.
     */
    private static final Map<String, String> ARRIVAL_HEADLINES = Map.of(
        "LAUGHTER", "웃음 영상이 도착했어요",
        "CLAP", "박수 소리가 담긴 영상이 도착했어요",
        "WAKE_WORD", "부르는 소리를 듣고 담았어요",
        "TOUCH", "카메라에서 직접 담은 영상이 도착했어요");
    private static final String DEFAULT_ARRIVAL_HEADLINE = "새 추억 영상이 도착했어요";

    private VideoEventTypes() {
    }

    /** 기기가 스스로 잡아서 담은 영상인가 — 알림을 보낼 대상인지 가른다. */
    public static boolean isDetection(List<String> eventTypes) {
        return eventTypes.stream().anyMatch(DETECTION_TYPES::contains);
    }

    /**
     * 알림 제목. 여러 유형이 함께 잡혔으면 대표 유형({@link #PRESENTATION_ORDER}
     * 에서 가장 앞선 것)을 쓴다 — 웃음과 박수가 같이 잡힌 영상은 웃음으로
     * 알리는 것이 사용자가 기대하는 쪽이다.
     */
    public static String arrivalHeadline(List<String> eventTypes) {
        return PRESENTATION_ORDER.stream()
            .filter(eventTypes::contains)
            .map(ARRIVAL_HEADLINES::get)
            .filter(Objects::nonNull)
            .findFirst()
            .orElse(DEFAULT_ARRIVAL_HEADLINE);
    }

    public static List<String> normalize(String triggerType, List<String> requestedTypes) {
        List<String> source = requestedTypes == null || requestedTypes.isEmpty()
            ? List.of(triggerType)
            : requestedTypes;
        LinkedHashSet<String> unique = new LinkedHashSet<>(source);
        if (unique.size() != source.size()) {
            throw new IllegalArgumentException("eventTypes cannot contain duplicates");
        }
        if (unique.size() > 3 || !unique.contains(triggerType)) {
            throw new IllegalArgumentException(
                "eventTypes must contain triggerType and at most three values");
        }
        if (!ALLOWED_TYPES.containsAll(unique)) {
            throw new IllegalArgumentException("eventTypes contains an unsupported value");
        }
        return PRESENTATION_ORDER.stream().filter(unique::contains).toList();
    }

    public static String toCsv(List<String> eventTypes) {
        return String.join(",", eventTypes);
    }

    public static List<String> fromCsv(String eventTypesCsv, String fallbackTriggerType) {
        if (eventTypesCsv == null || eventTypesCsv.isBlank()) {
            return List.of(fallbackTriggerType);
        }
        return List.copyOf(Arrays.asList(eventTypesCsv.split(",")));
    }
}
