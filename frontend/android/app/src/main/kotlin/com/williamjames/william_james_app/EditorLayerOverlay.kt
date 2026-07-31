package com.williamjames.william_james_app

import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableString
import android.text.style.AbsoluteSizeSpan
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
        return TimedLayerText(
            startUs = startMs * 1000,
            endUs = endMs * 1000,
            value = text,
            color = color,
            backgroundColor = backgroundColor,
            fontSize = scaled(fontSize, fontScale),
            bold = bold,
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
            settings = settings(raw),
        )
    }

    private fun scaled(fontSize: Int, fontScale: Float): Int =
        (fontSize * fontScale).roundToInt().coerceIn(8, 640)

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
        private val value: String,
        private val color: Int,
        private val backgroundColor: Int,
        private val fontSize: Int,
        private val bold: Boolean,
        private val settings: OverlaySettings,
    ) : TextOverlay() {
        override fun getText(presentationTimeUs: Long): SpannableString {
            if (presentationTimeUs < startUs || presentationTimeUs >= endUs) {
                return SpannableString("")
            }
            return SpannableString(value).apply {
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
                if (bold) {
                    setSpan(
                        StyleSpan(Typeface.BOLD),
                        0,
                        length,
                        Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                    )
                }
            }
        }

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
            settings
    }
}
