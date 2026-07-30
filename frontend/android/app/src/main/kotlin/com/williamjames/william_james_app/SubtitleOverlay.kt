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
        private val cues: List<Cue>,
        private val color: Int,
    ) : TextOverlay() {
        // 손 자막과 같은 자리.
        private val settings = StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(0f, -0.72f)
            .build()

        override fun getText(presentationTimeUs: Long): SpannableString {
            val hit = cues.firstOrNull {
                presentationTimeUs >= it.startUs && presentationTimeUs < it.endUs
            }
            val span = SpannableString(hit?.text ?: "")
            if (span.isNotEmpty()) {
                // 손 자막과 같은 스타일 (색·배경·크기 54·굵게).
                span.setSpan(
                    ForegroundColorSpan(color),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                span.setSpan(
                    BackgroundColorSpan(0x99000000.toInt()),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                span.setSpan(
                    AbsoluteSizeSpan(54),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                span.setSpan(
                    StyleSpan(Typeface.BOLD),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
            return span
        }

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
            settings
    }
}
