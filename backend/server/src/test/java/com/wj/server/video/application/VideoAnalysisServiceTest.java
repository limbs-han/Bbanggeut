package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyFloat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.video.domain.VideoAnalysisRow;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoAnalysisMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VideoAnalysisServiceTest {
    private static final UUID USER_ID = UUID.randomUUID();
    private static final UUID VIDEO_ID = UUID.randomUUID();
    private static final UUID DEVICE_ID = UUID.randomUUID();
    private static final Instant AT = Instant.parse("2026-08-06T09:00:00Z");

    @Mock
    private VideoAnalysisMapper analysisMapper;
    @Mock
    private VideoMapper videoMapper;

    private VideoAnalysisService service() {
        return new VideoAnalysisService(analysisMapper, videoMapper);
    }

    private void accessible() {
        when(videoMapper.findAccessibleVideo(USER_ID, VIDEO_ID)).thenReturn(
            Optional.of(new VideoRow(
                VIDEO_ID, DEVICE_ID, "IOT_CAPTURE", "LAUGHTER", "event-1", "웃음 영상",
                "video/mp4", 100L, "a".repeat(64), 5000L, AT, AT.plusSeconds(5),
                "private/device/video.mp4", "READY", false, AT, "LAUGHTER")));
    }

    /** 분석한 적이 없는 영상은 오류가 아니다 — 화면이 "분석 시작" 버튼을 그린다. */
    @Test
    void aVideoThatWasNeverAnalyzedIsNoneNotAnError() {
        accessible();
        when(analysisMapper.find(VIDEO_ID)).thenReturn(Optional.empty());

        var status = service().status(USER_ID, VIDEO_ID);

        assertThat(status.status()).isEqualTo("NONE");
        assertThat(status.progress()).isZero();
    }

    @Test
    void aRunningAnalysisReportsItsStageAndProgress() {
        accessible();
        when(analysisMapper.find(VIDEO_ID)).thenReturn(Optional.of(new VideoAnalysisRow(
            VIDEO_ID, "RUNNING", "expression", 0.35f, null, USER_ID, AT, null)));

        var status = service().status(USER_ID, VIDEO_ID);

        assertThat(status.status()).isEqualTo("RUNNING");
        assertThat(status.stage()).isEqualTo("expression");
        assertThat(status.progress()).isEqualTo(0.35f);
        assertThat(status.finishedAt()).isNull();
    }

    /** 남의 금고 영상은 분석 여부조차 알려주지 않는다. */
    @Test
    void anInaccessibleVideoIsNotFoundAndNeverReadsTheAnalysis() {
        when(videoMapper.findAccessibleVideo(USER_ID, VIDEO_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service().status(USER_ID, VIDEO_ID))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("리소스를 찾을 수 없습니다");
        verify(analysisMapper, never()).find(any());
    }

    /** 워커가 이상한 값을 보내도 화면이 200%짜리 진행 막대를 그리면 안 된다. */
    @Test
    void progressIsClampedToZeroAndOne() {
        service().markProgress(VIDEO_ID, "video", 2.5f);
        service().markProgress(VIDEO_ID, "video", -1f);

        ArgumentCaptor<Float> values = ArgumentCaptor.forClass(Float.class);
        verify(analysisMapper, org.mockito.Mockito.times(2))
            .progressed(any(), anyString(), values.capture());
        assertThat(values.getAllValues()).containsExactly(1f, 0f);
    }

    /** 사유 없는 실패도 화면에 뭔가는 떠야 한다 — 빈 칸은 성공처럼 보인다. */
    @Test
    void aFailureWithoutAReasonStillGetsOne() {
        service().markFailed(VIDEO_ID, "   ", null);

        verify(analysisMapper).finished(VIDEO_ID, "FAILED", 0f, "알 수 없는 오류", null);
    }

    @Test
    void aVeryLongFailureReasonIsTrimmed() {
        service().markFailed(VIDEO_ID, "x".repeat(900), USER_ID);

        ArgumentCaptor<String> reason = ArgumentCaptor.forClass(String.class);
        verify(analysisMapper)
            .finished(any(), anyString(), anyFloat(), reason.capture(), any());
        assertThat(reason.getValue()).hasSize(500);
    }
}
