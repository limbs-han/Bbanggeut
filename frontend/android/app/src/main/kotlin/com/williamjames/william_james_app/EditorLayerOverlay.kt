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
    fun from(
        rawTextLayers: List<Map<String, Any?>>,
        rawStickerLayers: List<Map<String, Any?>>,
        fontScale: Float = 1f,
    ): List<TextureOverlay> {
        val safeScale = fontScale.coerceIn(0.25f, 4f)
        val overlays = mutableListOf<TextureOverlay>()
        rawTextLayers.mapNotNullTo(overlays) { textLayer(it, safeScale) }
        rawStickerLayers.mapNotNullTo(overlays) { stickerLayer(it, safeScale) }
        return overlays
    }

    private fun textLayer(raw: Map<String, Any?>, fontScale: Float): TextureOverlay? {
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
        return TimedLayerText(
            startUs = startMs * 1000,
            endUs = endMs * 1000,
            value = text,
            color = color,
            backgroundColor = backgroundColor,
            fontSize = scaled(fontSize, fontScale),
            bold = bold,
            italic = italic,
            alignment = alignment(raw["align"] as? String),
            settings = settings(raw),
        )
    }

    private fun stickerLayer(raw: Map<String, Any?>, fontScale: Float): TextureOverlay? {
        val value = raw["value"] as? String ?: return null
        if (value.isBlank()) return null
        val startMs = number(raw, "startMs")?.toLong() ?: return null
        val endMs = number(raw, "endMs")?.toLong() ?: return null
        if (endMs <= startMs) return null
        return TimedLayerText(
            startUs = startMs * 1000,
            endUs = endMs * 1000,
            value = value,
            color = 0xFFFFFFFF.toInt(),
            backgroundColor = 0x00000000,
            fontSize = scaled(STICKER_FONT_SIZE, fontScale),
            bold = false,
            italic = false,
            alignment = Layout.Alignment.ALIGN_CENTER,
            settings = settings(raw),
        )
    }

    private fun scaled(fontSize: Int, fontScale: Float): Int =
        (fontSize * fontScale).roundToInt().coerceIn(8, 640)

    /// 미리보기의 `EditorTextAlign`과 짝이다. 여러 줄일 때 줄들이 어느 쪽으로
    /// 붙는지를 정한다.
    private fun alignment(raw: String?): Layout.Alignment = when (raw) {
        "left" -> Layout.Alignment.ALIGN_NORMAL
        "right" -> Layout.Alignment.ALIGN_OPPOSITE
        else -> Layout.Alignment.ALIGN_CENTER
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

    private class TimedLayerText(
        private val startUs: Long,
        private val endUs: Long,
        value: String,
        color: Int,
        backgroundColor: Int,
        fontSize: Int,
        bold: Boolean,
        italic: Boolean,
        alignment: Layout.Alignment,
        private val settings: OverlaySettings,
    ) : TextOverlay() {
        /// 보일 때와 안 보일 때, 글은 이 둘뿐이다. 미리 만들어 두고 돌려준다.
        ///
        /// media3의 TextOverlay는 getText가 준 값이 **직전과 같을 때만** 글자
        /// 비트맵을 다시 만들지 않는다 (TextOverlay.getBitmap의
        /// `overlayText.equals(lastText)`). 프레임마다 새 SpannableString을
        /// 만들면 그 비교가 어긋난다 — 스팬끼리의 equals는 안드로이드 버전에
        /// 따라 참조 비교라서다. 그러면 글자 재기·배치·그리기와 GL 텍스처
        /// 업로드를 30fps 2분 영상에서 3600번 되풀이한다.
        ///
        /// 같은 인스턴스를 돌려주면 비교가 언제나 맞아, 글이 실제로 바뀌는
        /// 순간에만 다시 그린다.
        private val visible = SpannableString(value).apply {
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

        private val hidden = SpannableString("")

        override fun getText(presentationTimeUs: Long): SpannableString =
            if (presentationTimeUs < startUs || presentationTimeUs >= endUs) {
                hidden
            } else {
                visible
            }

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
            settings
    }
}
