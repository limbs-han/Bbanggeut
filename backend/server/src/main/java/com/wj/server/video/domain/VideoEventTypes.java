package com.wj.server.video.domain;

import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public final class VideoEventTypes {
    private static final List<String> PRESENTATION_ORDER = List.of(
        "LAUGHTER", "CLAP", "WAKE_WORD", "TOUCH", "MANUAL", "USER_UPLOAD", "EDIT");
    private static final Set<String> ALLOWED_TYPES = Set.copyOf(PRESENTATION_ORDER);

    private VideoEventTypes() {
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
