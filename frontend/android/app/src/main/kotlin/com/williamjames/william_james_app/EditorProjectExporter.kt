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

        // 잘랐다가 그대로 이어 붙인 조각은 하나로 되돌린다. 조각이 하나면
        // 스트림을 그대로 옮겨 담는 길이 열린다.
        val clips = mergeAdjacentClips(rawClips)

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

        // 이번 내보내기가 **화면을 다시 그려야 하는 일**인지 먼저 정한다.
        //
        // 프레임을 건드리지 않는다면 media3가 원본 영상 스트림을 그대로 옮겨
        // 담는다. 몇십 초 걸리던 저장이 몇 초로 끝나고 화질도 원본 그대로다.
        // 그러니 그 길을 막는 것(Presentation·코덱 강제)을 하나도 붙이지 않는다.
        //
        // **소리와 화면을 따로 따진다**: 예전에는 볼륨을 줄이거나 클립을 나누기만
        // 해도 "자르기만 한 게 아니다"로 보고 모든 프레임을 다시 인코딩했다.
        // 소리만 바꿨는데 화면까지 다시 그릴 이유가 없다 — media3는 트랙마다
        // 따로 정하므로 오디오만 다시 만들고 영상은 그대로 옮겨 담으면 된다.
        val hasOverlayWork = textLayers.isNotEmpty() ||
            stickerLayers.isNotEmpty() ||
            captions.isNotEmpty()
        val hasCanvasWork = canvasRatio != "original" ||
            scale != 1f ||
            rotation != 0f ||
            offsetX != 0f ||
            offsetY != 0f
        val hasVideoWork = hasOverlayWork || hasCanvasWork || lookEffect(look) != null

        // 영상 트랙을 통째로 다시 인코딩하지 않아도 되는가.
        //
        // media3는 조각이 둘 이상이면 화면을 안 건드려도 무조건 다시 인코딩한다
        // (`TransformerUtil.shouldTranscodeVideo`의 첫 줄이
        // `return !composition.transmuxVideo`다). 그래서 조각 수까지 따진다.
        // 하나짜리 자르기는 `experimentalSetTrimOptimizationEnabled`가 맨 앞
        // GOP만 다시 만들고 나머지를 복사하므로, 자른 위치는 프레임 단위로
        // 정확하면서 속도는 복사에 가깝다.
        val willTransmuxVideo = !hasVideoWork && clips.size == 1

        // 다시 그려야 하는 경우에만 크기를 맞춘다. 이때는 긴 변을
        // MAX_OUTPUT_LONG_EDGE로 제한한다 — 원본 비율이어도 마찬가지다.
        // 1080p를 그대로 다시 인코딩하면 720p보다 갑절 넘게 걸리는데, 손에
        // 들고 보는 영상에서 그 차이는 잘 드러나지 않는다.
        //
        // 반대로 그대로 옮겨 담을 수 있는 길이라면 이걸 붙이는 순간 그 길이
        // 막힌다. 화질도 손해, 속도도 손해다.
        val presentation = if (willTransmuxVideo) {
            null
        } else {
            Presentation.createForWidthAndHeight(
                targetWidth,
                targetHeight,
                Presentation.LAYOUT_SCALE_TO_FIT,
            )
        }

        val items = clips.mapNotNull { raw ->
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
        if (items.size != clips.size || items.isEmpty()) {
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
            // 소리를 건드리지 않았으면 소리는 그대로 옮겨 담는다.
            //
            // media3는 조각이 둘 이상이면 소리도 무조건 다시 인코딩한다
            // (`TransformerUtil.shouldTranscodeAudio`의 첫 줄). 화면을 다시
            // 그려야 해서 어차피 오래 걸리는 저장에서도, 소리까지 풀었다
            // 다시 만들 이유는 없다 — 시간도 들고 소리도 한 세대 나빠진다.
            .setTransmuxAudio(volume >= 0.999f)
            .build()

        // `experimentalSetMaxFramesInEncoder`는 **일부러 부르지 않는다.**
        //
        // 한동안 8을 넣어 두고 "인코더에 미리 채워 둔다"고 적어 두었는데,
        // 라이브러리를 뜯어보니 정반대였다. 기본값은 8이 아니라 제한 없음
        // (`C.LENGTH_UNSET`)이고, 그때 media3는 프레임을 자동으로 흘려보낸다.
        // 값을 넣는 순간 수동 모드로 바뀌어 "인코더에 떠 있는 프레임 수"를
        // 세면서 그 수를 넘지 않게 붙잡는다(`VideoSampleExporter`의
        // `maybeRenderEarliestOutputFrame`). 메모리를 아끼려는 손잡이지
        // 속도를 내는 손잡이가 아니다 — 빼는 쪽이 빠르다.
        val builder = Transformer.Builder(activity)
            .experimentalSetTrimOptimizationEnabled(willTransmuxVideo)
        // 코덱을 H.264로 못박는 건 화면을 다시 그릴 때만이다. 원본이 HEVC인데
        // 여기서 H.264를 요구하면 출력 형식이 입력과 달라져, 자르기만 해도
        // media3가 스트림 복사를 포기하고 전부 다시 인코딩한다.
        if (!willTransmuxVideo) {
            builder.setVideoMimeType(MimeTypes.VIDEO_H264)
        }

        val active = builder
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

    /// 원본에서 맞닿아 있는 조각들을 하나로 되돌린다.
    ///
    /// **왜 필요한가**: 분할해 놓고 아무것도 지우지 않으면 [0,t)와 [t,끝) 두
    /// 조각이 남는다. 이어 붙인 결과는 원본과 한 프레임도 다르지 않은데,
    /// media3는 조각이 둘 이상이라는 이유만으로 모든 프레임을 다시 인코딩한다.
    /// 붙여서 하나로 만들면 그대로 옮겨 담는 길이 열린다 — 결과는 똑같고,
    /// 화질은 원본 그대로이며, 몇십 초가 몇 초가 된다.
    ///
    /// 가운데를 지워 사이가 벌어진 조각들은 붙이지 않는다. 그건 실제로 다른
    /// 영상이라 다시 만들어야 한다.
    private fun mergeAdjacentClips(
        rawClips: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> {
        if (rawClips.size < 2) return rawClips
        val merged = mutableListOf<Map<String, Any?>>()
        for (clip in rawClips) {
            val previous = merged.lastOrNull()
            val previousEnd = previous?.let { number(it, "sourceEndMs")?.toLong() }
            val start = number(clip, "sourceStartMs")?.toLong()
            val joins = previous != null &&
                previousEnd != null &&
                start != null &&
                previousEnd == start &&
                previous["sourcePath"] == clip["sourcePath"]
            if (joins) {
                merged[merged.lastIndex] =
                    previous!! + ("sourceEndMs" to clip["sourceEndMs"])
            } else {
                merged += clip
            }
        }
        return merged
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
