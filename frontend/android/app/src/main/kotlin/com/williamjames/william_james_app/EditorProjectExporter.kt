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
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.MatrixTransformation
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
        val (targetWidth, targetHeight) = outputSize(aspectRatio)
        val scale = number(canvas, "scale")?.toFloat()?.coerceIn(1f, 4f) ?: 1f
        val rotation = number(canvas, "rotationDegrees")?.toFloat() ?: 0f
        val offsetX = number(canvas, "offsetX")?.toFloat()?.coerceIn(-1f, 1f) ?: 0f
        val offsetY = number(canvas, "offsetY")?.toFloat()?.coerceIn(-1f, 1f) ?: 0f
        val volume = number(audio, "sourceVolume")?.toFloat()?.coerceIn(0f, 1f) ?: 1f
        val presentation = Presentation.createForWidthAndHeight(
            targetWidth,
            targetHeight,
            Presentation.LAYOUT_SCALE_TO_FIT,
        )

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

        val overlays = EditorLayerOverlay.from(textLayers, stickerLayers).toMutableList()
        if (textLayers.isEmpty()) {
            SubtitleOverlay.of(captions, 0xFFFFFFFF.toInt())?.let(overlays::add)
        }
        val compositionEffects = if (overlays.isEmpty()) {
            Effects(emptyList(), emptyList())
        } else {
            Effects(emptyList(), listOf(OverlayEffect(overlays)))
        }
        val sequence = EditedMediaItemSequence.withAudioAndVideoFrom(items)
        val composition = Composition.Builder(sequence)
            .setEffects(compositionEffects)
            .build()

        val active = Transformer.Builder(activity)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
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
        presentation: Effect,
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
        val videoEffects = mutableListOf(presentation)
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

    private fun outputSize(aspectRatio: Double): Pair<Int, Int> =
        if (aspectRatio >= 1.0) {
            1280 to ((1280 / aspectRatio).roundToInt() / 2 * 2).coerceAtLeast(2)
        } else {
            ((1280 * aspectRatio).roundToInt() / 2 * 2).coerceAtLeast(2) to 1280
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
