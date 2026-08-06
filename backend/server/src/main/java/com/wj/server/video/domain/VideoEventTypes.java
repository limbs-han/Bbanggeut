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

    /**
     * 감지로 담긴 영상의 제목. <b>서버가 정한다 — 기기가 보낸 title을 쓰지
     * 않는다.</b>
     *
     * <p>같은 웃음 영상인데 목록과 알림에 세 가지 이름이 섞여 있었다. 기기
     * 스크립트가 저마다 다른 문자열을 들고 있었기 때문이다 —
     * {@code segment_clip_uploader.py}는 "웃음이 담긴 순간",
     * {@code laughter_clip_uploader.py}는 "웃음이 감지된 순간". 여기에 손으로
     * 부른 curl 한 번이 "웃음"을 넣자 2026-08-06 17:38 알림만 본문이 "웃음"으로
     * 떴다(실제로 겪은 일이다). 이름은 사용자에게 보이는 것이므로 클라이언트가
     * 아니라 서버가 쥔다 — 기기 스크립트를 몇 벌 고치든 화면은 흔들리지 않는다.
     *
     * <p>사람이 올린 영상(MANUAL·USER_UPLOAD·EDIT)은 여기 없다. 그 이름은
     * 올린 사람이 붙인 것이라 서버가 덮으면 안 된다.
     */
    private static final Map<String, String> ARRIVAL_TITLES = Map.of(
        "LAUGHTER", "웃음이 담긴 순간",
        "CLAP", "박수가 시작된 순간",
        "WAKE_WORD", "카메라를 부른 순간",
        "TOUCH", "카메라에서 직접 담은 순간");

    /**
     * 두 유형이 같이 잡혔을 때만 쓰는 이름. 대표 유형 하나로 줄이면 "웃음이
     * 담긴 순간"이 되어 박수가 함께 잡혔다는 사실이 사라진다.
     */
    private static final Map<Set<String>, String> MIXED_ARRIVAL_TITLES = Map.of(
        Set.of("LAUGHTER", "CLAP"), "웃음과 박수가 함께 담긴 순간");

    private VideoEventTypes() {
    }

    /**
     * 이 영상에 서버가 붙일 제목. 감지 유형이 아니면 {@code null}이고, 그때는
     * 부르는 쪽이 올린 사람의 제목을 그대로 쓴다.
     */
    public static String arrivalTitle(List<String> eventTypes) {
        String mixed = MIXED_ARRIVAL_TITLES.get(Set.copyOf(eventTypes));
        if (mixed != null) {
            return mixed;
        }
        return PRESENTATION_ORDER.stream()
            .filter(eventTypes::contains)
            .map(ARRIVAL_TITLES::get)
            .filter(Objects::nonNull)
            .findFirst()
            .orElse(null);
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
