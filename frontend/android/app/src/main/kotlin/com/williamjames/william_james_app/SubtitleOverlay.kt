package com.williamjames.william_james_app

import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableString
import android.text.style.AbsoluteSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
// OverlaySettings는 media3-effect가 아니라 media3-common에 있다 (1.9.2 확인).
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextOverlay
import androidx.media3.effect.TextureOverlay

/**
 * 시각마다 글이 바뀌는 자동 자막 오버레이.
 *
 * MainActivity에 코드를 늘리지 않으려고 여기에 모았다 — 저쪽에는 [of] 호출과
 * overlays.add 한 줄만 들어간다.
 *
 * 스타일과 자리는 손 자막(captionText)과 같게 맞췄다. 사용자가 보기에 자막이
 * 두 종류로 보이면 안 된다.
 *
 * 넘어오는 시각은 이미 잘린 클립 기준이다 (Dart의 captionsForExport가 옮겨
 * 준다). 시작 포함·끝 제외로 판정한다 — Dart의 captionAt과 같은 규칙이라야
 * 미리보기와 저장된 영상이 일치한다.
 */
@UnstableApi
object SubtitleOverlay {
    /** 쓸 만한 자막이 없으면 null — 호출부가 아무것도 추가하지 않는다. */
    fun of(rawSegments: List<Map<String, Any?>>, color: Int): TextureOverlay? {
        val cues = rawSegments.mapNotNull { entry ->
            val text = entry["text"] as? String ?: return@mapNotNull null
            val from = (entry["startMs"] as? Number)?.toLong() ?: return@mapNotNull null
            val to = (entry["endMs"] as? Number)?.toLong() ?: return@mapNotNull null
            if (text.isBlank() || to <= from) null
            else Cue(from * 1000, to * 1000, text)
        }
        if (cues.isEmpty()) return null
        return TimedText(cues, color)
    }

    private data class Cue(val startUs: Long, val endUs: Long, val text: String)

    private class TimedText(
        cues: List<Cue>,
        color: Int,
    ) : TextOverlay() {
        // 손 자막과 같은 자리.
        private val settings = StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(0f, -0.72f)
            .build()

        /// 자막이 없는 시각의 글. 빈 문자열이 **아니라** 공백 한 칸이다 —
        /// media3 TextOverlay.getBitmap은 글 너비 그대로 비트맵을 만들어서,
        /// 빈 문자열(너비 0)은 createBitmap이 "width and height must be > 0"
        /// 으로 던지고 내보내기 전체가 죽는다. 공백은 너비가 있으면서 그릴
        /// 픽셀이 없고, 아래 hiddenSettings가 알파 0으로 한 번 더 감춘다.
        private val hidden = SpannableString(" ")

        private val hiddenSettings = StaticOverlaySettings.Builder()
            .setAlphaScale(0f)
            .build()

        /// 줄마다 미리 만들어 같은 인스턴스를 돌려준다. TextOverlay는 getText
        /// 결과가 직전과 같을 때만 글자 비트맵을 다시 안 만드는데, 스팬의
        /// equals가 참조 비교라 프레임마다 새 SpannableString을 만들면 매
        /// 프레임 재기·그리기·GL 업로드를 되풀이한다.
        private val styledCues = cues.map { cue ->
            cue to SpannableString(cue.text).apply {
                // 손 자막과 같은 스타일 (색·배경·크기 54·굵게).
                setSpan(
                    ForegroundColorSpan(color),
                    0,
                    length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                setSpan(
                    BackgroundColorSpan(0x99000000.toInt()),
                    0,
                    length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                setSpan(
                    AbsoluteSizeSpan(54),
                    0,
                    length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                setSpan(
                    StyleSpan(Typeface.BOLD),
                    0,
                    length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
        }

        private fun activeAt(timeUs: Long): SpannableString? = styledCues
            .firstOrNull { timeUs >= it.first.startUs && timeUs < it.first.endUs }
            ?.second

        override fun getText(presentationTimeUs: Long): SpannableString =
            activeAt(presentationTimeUs) ?: hidden

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
            if (activeAt(presentationTimeUs) == null) hiddenSettings else settings
    }
}
