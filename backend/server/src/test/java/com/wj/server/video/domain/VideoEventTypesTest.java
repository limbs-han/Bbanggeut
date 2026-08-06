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

    /**
     * 제목은 서버가 정한다. 기기 스크립트가 저마다 다른 문자열을 들고 있어서
     * 같은 웃음 영상이 "웃음이 담긴 순간"·"웃음이 감지된 순간"·"웃음"으로
     * 섞여 나왔다.
     */
    @Test
    void namesEachDetectionTypeTheSameWayEveryTime() {
        assertThat(VideoEventTypes.arrivalTitle(List.of("LAUGHTER")))
            .isEqualTo("웃음이 담긴 순간");
        assertThat(VideoEventTypes.arrivalTitle(List.of("CLAP")))
            .isEqualTo("박수가 시작된 순간");
        assertThat(VideoEventTypes.arrivalTitle(List.of("WAKE_WORD")))
            .isEqualTo("카메라를 부른 순간");
        assertThat(VideoEventTypes.arrivalTitle(List.of("TOUCH")))
            .isEqualTo("카메라에서 직접 담은 순간");
    }

    /** 둘이 같이 잡혔다는 사실을 대표 유형 하나로 줄이면 잃는다. */
    @Test
    void keepsBothTypesInTheNameWhenLaughterAndClapArriveTogether() {
        assertThat(VideoEventTypes.arrivalTitle(List.of("LAUGHTER", "CLAP")))
            .isEqualTo("웃음과 박수가 함께 담긴 순간");
    }

    /** 사람이 붙인 이름은 서버가 덮지 않는다. */
    @Test
    void leavesHumanUploadsToKeepTheirOwnName() {
        assertThat(VideoEventTypes.arrivalTitle(List.of("USER_UPLOAD"))).isNull();
        assertThat(VideoEventTypes.arrivalTitle(List.of("MANUAL"))).isNull();
        assertThat(VideoEventTypes.arrivalTitle(List.of("EDIT"))).isNull();
    }
}
