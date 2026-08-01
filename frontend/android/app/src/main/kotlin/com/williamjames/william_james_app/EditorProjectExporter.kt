package com.williamjames.william_james_app

import android.app.Activity
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.DefaultGainProvider
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.HslAdjustment
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.MatrixTransformation
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.roundToInt

@UnstableApi
class EditorProjectExporter(
    private val activity: Activity,
) {
    companion object {
        /// Flutter 미리보기가 글자 크기를 계산할 때 쓰는 기준 캔버스 너비
        /// (local_edit_screen.dart의 `_referenceCanvasWidth`와 같은 값).
        private const val REFERENCE_CANVAS_WIDTH = 1280f

        /// 다시 인코딩할 때 만드는 영상의 긴 변 상한.
        private const val MAX_OUTPUT_LONG_EDGE = 1280
    }

    private var transformer: Transformer? = null
    private var pendingResult: MethodChannel.Result? = null
    private var phase = "idle"
    private var lastProgress = 0

    fun handles(method: String): Boolean =
        method == "loadMediaMetadata" ||
            method == "exportProject" ||
            method == "getExportProgress" ||
            method == "cancelExport"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadMediaMetadata" -> loadMediaMetadata(call, result)
            "exportProject" -> exportProject(call, result)
            "getExportProgress" -> reportProgress(result)
            "cancelExport" -> cancel(result)
            else -> result.notImplemented()
        }
    }

    private fun loadMediaMetadata(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath")
        if (inputPath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "inputPath is required.", null)
            return
        }
        val input = File(inputPath)
        if (!input.isFile) {
            result.error("INPUT_NOT_FOUND", "The source video does not exist.", null)
            return
        }
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(input.absolutePath)
                val metadata = mapOf(
                    "durationMs" to (
                        retriever.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_DURATION,
                        )?.toLongOrNull() ?: 0L
                    ),
                    "width" to (
                        retriever.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
                        )?.toIntOrNull() ?: 0
                    ),
                    "height" to (
                        retriever.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
                        )?.toIntOrNull() ?: 0
                    ),
                    "rotationDegrees" to (
                        retriever.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                        )?.toIntOrNull() ?: 0
                    ),
                )
                activity.runOnUiThread { result.success(metadata) }
            } catch (failure: Exception) {
                activity.runOnUiThread {
                    result.error(
                        "METADATA_FAILED",
                        failure.message ?: "Video metadata could not be read.",
                        null,
                    )
                }
            } finally {
                retriever.release()
            }
        }.start()
    }

    private fun exportProject(call: MethodCall, result: MethodChannel.Result) {
        if (transformer != null) {
            result.error("EXPORT_BUSY", "A video export is already running.", null)
            return
        }
        val outputPath = call.argument<String>("outputPath")
        val rawClips = call.argument<List<Map<String, Any?>>>("clips") ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val canvas = call.argument<Map<String, Any?>>("canvas") ?: emptyMap()
        @Suppress("UNCHECKED_CAST")
        val audio = call.argument<Map<String, Any?>>("audio") ?: emptyMap()
        val textLayers = call.argument<List<Map<String, Any?>>>("textLayers") ?: emptyList()
        val stickerLayers =
            call.argument<List<Map<String, Any?>>>("stickerLayers") ?: emptyList()
        val blurLayers = call.argument<List<Map<String, Any?>>>("blurLayers") ?: emptyList()
        val captions = call.argument<List<Map<String, Any?>>>("captions") ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val sourceSize = call.argument<Map<String, Any?>>("sourceSize") ?: emptyMap()
        // 앱 안 AR 효과와 필터가 정한 색감. 미리보기의 ColorFilter와 짝이다.
        val look = call.argument<String>("look") ?: "none"

        if (outputPath.isNullOrBlank() || rawClips.isEmpty()) {
            result.error(
                "INVALID_ARGUMENT",
                "outputPath and at least one clip are required.",
                null,
            )
            return
        }
        if (blurLayers.isNotEmpty()) {
            result.error(
                "UNSUPPORTED_BLUR",
                "Region blur requires the custom shader pipeline and is not enabled.",
                null,
            )
            return
        }
        if (rawClips.any { !(it["arEffectId"] as? String).isNullOrBlank() }) {
            result.error(
                "AR_LOCAL_VIDEO_UNAVAILABLE",
                "The installed Face AR license does not expose local-video rendering.",
                null,
            )
            return
        }

        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists() && !outputFile.delete()) {
            result.error(
                "OUTPUT_NOT_WRITABLE",
                "The old output file could not be replaced.",
                null,
            )
            return
        }

        val aspectRatio = number(canvas, "aspectRatio")?.toDouble()?.coerceIn(0.4, 2.5)
            ?: (16.0 / 9.0)
        // 원본보다 크게 만들지 않는다. 예전에는 비율만 보고 언제나 긴 변을
        // 1280으로 잡아, 720p보다 작은 원본을 굳이 키워 인코딩했다 — 화질은
        // 그대로인데 그릴 픽셀만 늘어난다.
        val sourceLongEdge = maxOf(
            number(sourceSize, "width")?.toInt() ?: 0,
            number(sourceSize, "height")?.toInt() ?: 0,
        )
        val longEdge = if (sourceLongEdge > 0) {
            minOf(MAX_OUTPUT_LONG_EDGE, sourceLongEdge)
        } else {
            MAX_OUTPUT_LONG_EDGE
        }
        val (targetWidth, targetHeight) = outputSize(aspectRatio, longEdge)
        val canvasRatio = canvas["ratio"] as? String ?: "original"
        val scale = number(canvas, "scale")?.toFloat()?.coerceIn(1f, 4f) ?: 1f
        val rotation = number(canvas, "rotationDegrees")?.toFloat() ?: 0f
        val offsetX = number(canvas, "offsetX")?.toFloat()?.coerceIn(-1f, 1f) ?: 0f
        val offsetY = number(canvas, "offsetY")?.toFloat()?.coerceIn(-1f, 1f) ?: 0f
        val volume = number(audio, "sourceVolume")?.toFloat()?.coerceIn(0f, 1f) ?: 1f
        // 컷 편집만 한 경우 Presentation을 넣지 않아 Transformer가 가능한
        // 입력에서는 재인코딩 대신 빠른 스트림 복사를 선택할 수 있게 한다.
        val presentation = if (canvasRatio == "original") {
            null
        } else {
            Presentation.createForWidthAndHeight(
                targetWidth,
                targetHeight,
                Presentation.LAYOUT_SCALE_TO_FIT,
            )
        }

        val items = rawClips.mapNotNull { raw ->
            editedItem(
                raw,
                presentation,
                scale,
                rotation,
                offsetX,
                offsetY,
                volume,
            )
        }
        if (items.size != rawClips.size || items.isEmpty()) {
            result.error("INVALID_CLIP", "One or more clips are invalid.", null)
            return
        }

        // 글자·스티커 크기는 Flutter 미리보기가 기준 너비 1280으로 계산한다.
        // 실제 출력이 그보다 크거나 작으면 같은 비율로 맞춰 줘야 미리보기에서
        // 본 크기가 저장된 영상에서도 같다.
        val overlayCanvasWidth = if (presentation == null) {
            number(sourceSize, "width")?.toInt()?.takeIf { it > 0 } ?: targetWidth
        } else {
            targetWidth
        }
        val fontScale = overlayCanvasWidth / REFERENCE_CANVAS_WIDTH
        val overlays =
            EditorLayerOverlay.from(textLayers, stickerLayers, fontScale).toMutableList()
        if (textLayers.isEmpty()) {
            SubtitleOverlay.of(captions, 0xFFFFFFFF.toInt())?.let(overlays::add)
        }
        val compositionVideoEffects = mutableListOf<Effect>()
        // 색감을 먼저 입히고 그 위에 글자를 얹는다. 순서를 바꾸면 흑백 필터가
        // 자막까지 회색으로 만든다.
        lookEffect(look)?.let(compositionVideoEffects::add)
        if (overlays.isNotEmpty()) {
            compositionVideoEffects += OverlayEffect(overlays)
        }
        val compositionEffects = Effects(emptyList(), compositionVideoEffects)
        val sequence = EditedMediaItemSequence.withAudioAndVideoFrom(items)
        val composition = Composition.Builder(sequence)
            .setEffects(compositionEffects)
            .build()

        // 자르기만 한 내보내기는 화면에 그릴 것이 하나도 없다. media3에 알려
        // 주면 프레임을 다시 인코딩하지 않고 그대로 옮겨 담아(맨 앞 GOP만
        // 다시 만든다) 몇십 초 걸리던 저장이 몇 초로 끝난다.
        //
        // 조건을 여기서 직접 따진다. media3도 못 쓰는 경우를 스스로 알아채
        // 보통 경로로 되돌아가지만, 그 판단에 드는 시간을 애초에 만들지 않는다.
        val trimOnly = presentation == null &&
            compositionVideoEffects.isEmpty() &&
            items.size == 1 &&
            volume >= 0.999f &&
            scale == 1f &&
            rotation == 0f &&
            offsetX == 0f &&
            offsetY == 0f

        val active = Transformer.Builder(activity)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .experimentalSetTrimOptimizationEnabled(trimOnly)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(
                        composition: Composition,
                        exportResult: ExportResult,
                    ) {
                        finishSuccess(outputFile)
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finishError(
                            "EXPORT_FAILED",
                            exportException.message ?: "The video could not be exported.",
                        )
                    }
                },
            )
            .build()

        transformer = active
        pendingResult = result
        phase = "rendering"
        lastProgress = 0
        try {
            active.start(composition, outputPath)
        } catch (failure: Exception) {
            finishError(
                "EXPORT_FAILED",
                failure.message ?: "The video could not be exported.",
            )
        }
    }

    private fun editedItem(
        raw: Map<String, Any?>,
        presentation: Effect?,
        scale: Float,
        rotation: Float,
        offsetX: Float,
        offsetY: Float,
        volume: Float,
    ): EditedMediaItem? {
        val sourcePath = raw["sourcePath"] as? String ?: return null
        val input = File(sourcePath)
        if (!input.isFile) return null
        val startMs = number(raw, "sourceStartMs")?.toLong() ?: return null
        val endMs = number(raw, "sourceEndMs")?.toLong() ?: return null
        if (endMs <= startMs) return null
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(input))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(startMs)
                    .setEndPositionMs(endMs)
                    .build(),
            )
            .build()
        val audioProcessors = mutableListOf<AudioProcessor>()
        if (volume < 0.999f) {
            audioProcessors += GainProcessor(
                DefaultGainProvider.Builder(volume).build(),
            )
        }
        val videoEffects = mutableListOf<Effect>()
        presentation?.let(videoEffects::add)
        if (scale != 1f || rotation != 0f || offsetX != 0f || offsetY != 0f) {
            videoEffects += CanvasMatrixTransformation(
                scale = scale,
                rotationDegrees = rotation,
                offsetX = offsetX,
                offsetY = offsetY,
            )
        }
        return EditedMediaItem.Builder(mediaItem)
            .setEffects(Effects(audioProcessors, videoEffects))
            .build()
    }

    private fun reportProgress(result: MethodChannel.Result) {
        val active = transformer
        if (active == null) {
            result.success(mapOf("phase" to phase, "progress" to lastProgress / 100.0))
            return
        }
        val holder = ProgressHolder()
        val state = active.getProgress(holder)
        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
            lastProgress = holder.progress.coerceIn(0, 100)
        }
        result.success(mapOf("phase" to phase, "progress" to lastProgress / 100.0))
    }

    private fun cancel(result: MethodChannel.Result) {
        val active = transformer
        if (active == null) {
            result.success(false)
            return
        }
        active.cancel()
        transformer = null
        phase = "cancelled"
        pendingResult?.error("EXPORT_CANCELLED", "The video export was cancelled.", null)
        pendingResult = null
        result.success(true)
    }

    fun dispose() {
        transformer?.cancel()
        transformer = null
        pendingResult?.error(
            "EXPORT_CANCELLED",
            "The editor was closed during export.",
            null,
        )
        pendingResult = null
        phase = "cancelled"
    }

    private fun finishSuccess(outputFile: File) {
        val result = pendingResult
        transformer = null
        pendingResult = null
        if (outputFile.isFile && outputFile.length() > 0L) {
            phase = "completed"
            lastProgress = 100
            result?.success(outputFile.absolutePath)
        } else {
            phase = "failed"
            result?.error("EXPORT_EMPTY", "The exported file is empty.", null)
        }
    }

    private fun finishError(code: String, message: String) {
        val result = pendingResult
        transformer = null
        pendingResult = null
        phase = "failed"
        result?.error(code, message, null)
    }

    /// 미리보기 `_lookFilter`와 같은 색감을 media3 쪽에서 재현한다.
    private fun lookEffect(look: String): Effect? = when (look) {
        "mono" -> RgbFilter.createGrayscaleFilter()
        "warm" -> HslAdjustment.Builder()
            .adjustHue(6f)
            .adjustSaturation(12f)
            .adjustLightness(3f)
            .build()
        "vivid" -> HslAdjustment.Builder()
            .adjustSaturation(28f)
            .adjustLightness(4f)
            .build()
        "soft" -> HslAdjustment.Builder()
            .adjustSaturation(-10f)
            .adjustLightness(8f)
            .build()
        else -> null
    }

    private fun outputSize(aspectRatio: Double, longEdge: Int): Pair<Int, Int> {
        val edge = (longEdge / 2 * 2).coerceAtLeast(2)
        return if (aspectRatio >= 1.0) {
            edge to ((edge / aspectRatio).roundToInt() / 2 * 2).coerceAtLeast(2)
        } else {
            ((edge * aspectRatio).roundToInt() / 2 * 2).coerceAtLeast(2) to edge
        }
    }

    private fun number(raw: Map<String, Any?>, key: String): Number? =
        raw[key] as? Number

    private class CanvasMatrixTransformation(
        private val scale: Float,
        private val rotationDegrees: Float,
        private val offsetX: Float,
        private val offsetY: Float,
    ) : MatrixTransformation {
        override fun getMatrix(presentationTimeUs: Long): Matrix =
            Matrix().apply {
                postScale(scale, scale)
                postRotate(rotationDegrees)
                postTranslate(offsetX, -offsetY)
            }
    }
}
