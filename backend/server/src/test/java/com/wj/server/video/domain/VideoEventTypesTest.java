package com.wj.server.video.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;

import org.junit.jupiter.api.Test;

class VideoEventTypesTest {
    @Test
    void normalizesMixedTypesInPresentationOrder() {
        assertThat(VideoEventTypes.normalize(
            "LAUGHTER", List.of("CLAP", "LAUGHTER")))
            .containsExactly("LAUGHTER", "CLAP");
    }

    @Test
    void defaultsToPrimaryTypeForLegacyRequests() {
        assertThat(VideoEventTypes.normalize("TOUCH", null))
            .containsExactly("TOUCH");
    }

    @Test
    void rejectsDuplicatesAndMissingPrimaryType() {
        assertThatThrownBy(() -> VideoEventTypes.normalize(
            "LAUGHTER", List.of("LAUGHTER", "LAUGHTER")))
            .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> VideoEventTypes.normalize(
            "LAUGHTER", List.of("CLAP")))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void roundTripsCsvStorage() {
        var types = List.of("LAUGHTER", "CLAP");
        assertThat(VideoEventTypes.fromCsv(
            VideoEventTypes.toCsv(types), "LAUGHTER"))
            .containsExactlyElementsOf(types);
    }
}
