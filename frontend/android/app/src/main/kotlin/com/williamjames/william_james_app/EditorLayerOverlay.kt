package com.williamjames.william_james_app

import android.graphics.Typeface
import android.text.Layout
import android.text.Spannable
import android.text.SpannableString
import android.text.style.AbsoluteSizeSpan
import android.text.style.AlignmentSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextOverlay
import androidx.media3.effect.TextureOverlay
import kotlin.math.roundToInt

@UnstableApi
object EditorLayerOverlay {
    /// 스티커 기본 글자 크기. 미리보기(local_edit_screen.dart의
    /// `_referenceStickerFontSize`)와 같은 값이어야 한다.
    private const val STICKER_FONT_SIZE = 110

    /// [fontScale]은 출력 영상 너비 / 기준 너비(1280)다. 미리보기에서 본 글자
    /// 크기를 해상도가 다른 출력에서도 같은 비율로 재현한다.
    ///
    /// **오버레이는 레이어당 하나가 아니라 "레인"당 하나다.** media3의
    /// OverlayShaderProgram은 오버레이마다 텍스처 샘플러를 하나씩 붙인
    /// 셰이더 하나를 만들고, SDR 오버레이 15개를 넘으면 그 자리에서 던진다
    /// ("does not support more than 15 SDR overlays") — 그게 내보내기의
    /// "video frame processing error"였다. AI 자막은 대사 한 줄이 레이어
    /// 하나라 쉽게 수십 개가 되지만, 같은 시각에 함께 보이는 레이어는 몇 개
    /// 없다. 그래서 시간이 겹치지 않는 레이어들이 오버레이 하나를 나눠 쓰게
    /// 묶는다 — 오버레이 수가 "전체 레이어 수"에서 "동시에 보이는 최대
    /// 개수"로 줄어든다. SubtitleOverlay가 처음부터 쓰던 구조와 같다.
    fun from(
        rawTextLayers: List<Map<String, Any?>>,
        rawStickerLayers: List<Map<String, Any?>>,
        fontScale: Float = 1f,
    ): List<TextureOverlay> {
        val safeScale = fontScale.coerceIn(0.25f, 4f)
        // 글자와 스티커는 레인을 섞지 않는다 — 오버레이는 목록 순서대로
        // 그려지므로, 이렇게 해야 예전처럼 스티커가 언제나 글자 위에 얹힌다.
        val overlays = mutableListOf<TextureOverlay>()
        overlays += laneOverlays(rawTextLayers.mapNotNull { textEntry(it, safeScale) })
        overlays += laneOverlays(rawStickerLayers.mapNotNull { stickerEntry(it, safeScale) })
        return overlays
    }

    /// 시작 시각 순으로 훑으며, 마지막 항목이 이미 끝난 레인에 이어 붙인다.
    /// 겹치는 항목만 새 레인을 연다(구간 그리디 배치). 레인 수 = 같은 시각에
    /// 함께 보이는 최대 개수.
    private fun laneOverlays(entries: List<Entry>): List<TextureOverlay> {
        if (entries.isEmpty()) return emptyList()
        val lanes = mutableListOf<MutableList<Entry>>()
        for (entry in entries.sortedBy { it.startUs }) {
            val lane = lanes.firstOrNull { it.last().endUs <= entry.startUs }
            if (lane != null) lane.add(entry) else lanes.add(mutableListOf(entry))
        }
        return lanes.map { LaneOverlay(it) }
    }

    private fun textEntry(raw: Map<String, Any?>, fontScale: Float): Entry? {
        val text = raw["text"] as? String ?: return null
        if (text.isBlank()) return null
        val startMs = number(raw, "startMs")?.toLong() ?: return null
        val endMs = number(raw, "endMs")?.toLong() ?: return null
        if (endMs <= startMs) return null
        val color = number(raw, "color")?.toInt() ?: 0xFFFFFFFF.toInt()
        val backgroundColor = number(raw, "backgroundColor")?.toInt()
            ?: 0x99000000.toInt()
        val fontSize = number(raw, "fontSize")?.toInt()?.coerceIn(16, 160) ?: 42
        val bold = raw["bold"] as? Boolean ?: true
        val italic = raw["italic"] as? Boolean ?: false
        return Entry(
            startUs = startMs * 1000,
            endUs = endMs * 1000,
            text = styled(
                value = text,
                color = color,
                backgroundColor = backgroundColor,
                fontSize = scaled(fontSize, fontScale),
                bold = bold,
                italic = italic,
                alignment = alignment(raw["align"] as? String),
            ),
            staticSettings = settings(raw),
        )
    }

    private fun stickerEntry(raw: Map<String, Any?>, fontScale: Float): Entry? {
        val value = raw["value"] as? String ?: return null
        if (value.isBlank()) return null
        val startMs = number(raw, "startMs")?.toLong() ?: return null
        val endMs = number(raw, "endMs")?.toLong() ?: return null
        if (endMs <= startMs) return null
        return Entry(
            startUs = startMs * 1000,
            endUs = endMs * 1000,
            text = styled(
                value = value,
                color = 0xFFFFFFFF.toInt(),
                backgroundColor = 0x00000000,
                fontSize = scaled(STICKER_FONT_SIZE, fontScale),
                bold = false,
                italic = false,
                alignment = Layout.Alignment.ALIGN_CENTER,
            ),
            staticSettings = settings(raw),
            // 얼굴 추적 스티커. 키프레임(타임라인 ms 기준 x·y)을 프레임마다
            // 보간해 얼굴을 따라 움직인다. 미리보기(_resolveFaceSticker)와
            // 같은 좌표라 화면에서 본 그대로 구워진다.
            track = positionTrack(raw),
            trackScale = (number(raw, "scale")?.toFloat() ?: 1f).coerceIn(0.2f, 4f),
            trackRotationDegrees = number(raw, "rotationDegrees")?.toFloat() ?: 0f,
        )
    }

    /// 스티커 DTO의 `track`([{ms, x, y, s}]) 키프레임. 없으면 null — 고정
    /// 위치다. `s`는 얼굴 크기·구간 줌이 구워진 배율 계수(없으면 1)다.
    private fun positionTrack(raw: Map<String, Any?>): List<TrackSample>? {
        val rawTrack = raw["track"] as? List<*> ?: return null
        val samples = rawTrack.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            val ms = (map["ms"] as? Number)?.toLong() ?: return@mapNotNull null
            val x = (map["x"] as? Number)?.toFloat() ?: return@mapNotNull null
            val y = (map["y"] as? Number)?.toFloat() ?: return@mapNotNull null
            val s = (map["s"] as? Number)?.toFloat() ?: 1f
            TrackSample(
                ms * 1000,
                x.coerceIn(0f, 1f),
                y.coerceIn(0f, 1f),
                s.coerceIn(0.1f, 8f),
            )
        }
        return samples.sortedBy { it.timeUs }.ifEmpty { null }
    }

    private data class TrackSample(
        val timeUs: Long,
        val x: Float,
        val y: Float,
        val scale: Float = 1f,
    )

    /// 레인 하나에 들어가는 레이어 하나. 글자 비트맵 캐시가 살아 있도록
    /// SpannableString을 미리 만들어 같은 인스턴스로 돌려준다(아래
    /// [LaneOverlay] 참조).
    private class Entry(
        val startUs: Long,
        val endUs: Long,
        val text: SpannableString,
        val staticSettings: OverlaySettings,
        /// null이면 고정 위치([staticSettings]). 있으면 프레임마다 보간한다.
        val track: List<TrackSample>? = null,
        val trackScale: Float = 1f,
        val trackRotationDegrees: Float = 0f,
    )

    private fun scaled(fontSize: Int, fontScale: Float): Int =
        (fontSize * fontScale).roundToInt().coerceIn(8, 640)

    /// 미리보기의 `EditorTextAlign`과 짝이다. 여러 줄일 때 줄들이 어느 쪽으로
    /// 붙는지를 정한다.
    private fun alignment(raw: String?): Layout.Alignment = when (raw) {
        "left" -> Layout.Alignment.ALIGN_NORMAL
        "right" -> Layout.Alignment.ALIGN_OPPOSITE
        else -> Layout.Alignment.ALIGN_CENTER
    }

    private fun styled(
        value: String,
        color: Int,
        backgroundColor: Int,
        fontSize: Int,
        bold: Boolean,
        italic: Boolean,
        alignment: Layout.Alignment,
    ): SpannableString = SpannableString(value).apply {
        setSpan(
            ForegroundColorSpan(color),
            0,
            length,
            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        if (backgroundColor ushr 24 != 0) {
            setSpan(
                BackgroundColorSpan(backgroundColor),
                0,
                length,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        setSpan(
            AbsoluteSizeSpan(fontSize),
            0,
            length,
            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        val typefaceStyle = when {
            bold && italic -> Typeface.BOLD_ITALIC
            bold -> Typeface.BOLD
            italic -> Typeface.ITALIC
            else -> Typeface.NORMAL
        }
        if (typefaceStyle != Typeface.NORMAL) {
            setSpan(
                StyleSpan(typefaceStyle),
                0,
                length,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        setSpan(
            AlignmentSpan.Standard(alignment),
            0,
            length,
            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
    }

    private fun settings(raw: Map<String, Any?>): OverlaySettings {
        @Suppress("UNCHECKED_CAST")
        val position = raw["position"] as? Map<String, Any?> ?: emptyMap()
        val normalizedX = (number(position, "x")?.toFloat() ?: 0.5f).coerceIn(0f, 1f)
        val normalizedY = (number(position, "y")?.toFloat() ?: 0.5f).coerceIn(0f, 1f)
        val scale = (number(raw, "scale")?.toFloat() ?: 1f).coerceIn(0.2f, 4f)
        val rotation = number(raw, "rotationDegrees")?.toFloat() ?: 0f
        return StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(normalizedX * 2f - 1f, 1f - normalizedY * 2f)
            .setScale(scale, scale)
            .setRotationDegrees(rotation)
            .build()
    }

    private fun number(raw: Map<String, Any?>, key: String): Number? =
        raw[key] as? Number

    /// 시간이 겹치지 않는 레이어들이 나눠 쓰는 오버레이 하나.
    ///
    /// media3의 TextOverlay는 getText가 준 값이 **직전과 같을 때만** 글자
    /// 비트맵을 다시 만들지 않는다 (TextOverlay.getBitmap의
    /// `overlayText.equals(lastText)`). 스팬끼리의 equals는 안드로이드 버전에
    /// 따라 참조 비교라, 항목마다 미리 만들어 둔 같은 SpannableString
    /// 인스턴스를 돌려준다 — 비트맵은 항목이 실제로 바뀌는 순간에만 다시
    /// 그려진다.
    private class LaneOverlay(entries: List<Entry>) : TextOverlay() {
        private val sorted = entries.sortedBy { it.startUs }

        /// 안 보일 때의 글은 빈 문자열이 **아니라** 공백 한 칸이다. media3의
        /// TextOverlay.getBitmap은 글 너비 그대로 비트맵을 만드는데, 빈
        /// 문자열은 너비가 0이라 createBitmap이 "width and height must be
        /// > 0"으로 던진다 — 자막이 화면에 없는 시각의 프레임 하나만 있어도
        /// 내보내기 전체가 "video frame processing error"로 죽었다. 공백은
        /// 너비가 있으면서 그릴 픽셀이 없고, 아래 idleSettings가 알파 0으로
        /// 한 번 더 감춘다.
        private val hidden = SpannableString(" ")

        private val idleSettings = StaticOverlaySettings.Builder()
            .setAlphaScale(0f)
            .build()

        private fun activeAt(timeUs: Long): Entry? = sorted.firstOrNull {
            timeUs >= it.startUs && timeUs < it.endUs
        }

        override fun getText(presentationTimeUs: Long): SpannableString =
            activeAt(presentationTimeUs)?.text ?: hidden

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
            val entry = activeAt(presentationTimeUs) ?: return idleSettings
            val samples = entry.track ?: return entry.staticSettings
            val sample = sampleAt(samples, presentationTimeUs)
            // 얼굴 크기·구간 줌이 구워진 배율 계수를 스티커 배율에 곱한다 —
            // 미리보기(_resolveFaceSticker)와 같은 식이다.
            val drawScale = entry.trackScale * sample.scale
            // 글자 비트맵과 달리 설정 객체는 media3가 캐시하지 않아서 프레임마다
            // 새로 만들어도 재기·그리기가 되풀이되지 않는다.
            return StaticOverlaySettings.Builder()
                .setBackgroundFrameAnchor(sample.x * 2f - 1f, 1f - sample.y * 2f)
                .setScale(drawScale, drawScale)
                .setRotationDegrees(entry.trackRotationDegrees)
                .build()
        }

        /// 이웃 키프레임을 선형 보간한다. 트랙 밖 시각은 가장 가까운 표본이다.
        private fun sampleAt(
            samples: List<TrackSample>,
            timeUs: Long,
        ): TrackSample {
            if (timeUs <= samples.first().timeUs) return samples.first()
            if (timeUs >= samples.last().timeUs) return samples.last()
            for (index in 1 until samples.size) {
                val next = samples[index]
                if (timeUs > next.timeUs) continue
                val prev = samples[index - 1]
                val span = (next.timeUs - prev.timeUs).toFloat()
                if (span <= 0f) return next
                val t = (timeUs - prev.timeUs) / span
                return TrackSample(
                    timeUs,
                    prev.x + (next.x - prev.x) * t,
                    prev.y + (next.y - prev.y) * t,
                    prev.scale + (next.scale - prev.scale) * t,
                )
            }
            return samples.last()
        }
    }
}
