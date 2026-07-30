package com.williamjames.william_james_app

import android.content.ContentValues
import android.graphics.Typeface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.text.Spannable
import android.text.SpannableString
import android.text.style.AbsoluteSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
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
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextOverlay
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import kotlin.math.roundToInt

@UnstableApi
class MainActivity : FlutterActivity() {
    companion object {
        private const val VIDEO_CANVAS_CHANNEL = "com.williamjames/video_canvas"
    }

    private var activeTransformer: Transformer? = null
    private var activeResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VIDEO_CANVAS_CHANNEL,
        ).setMethodCallHandler(::handleVideoCanvasCall)
        SttChannel.register(flutterEngine)
    }

    private fun handleVideoCanvasCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "generateThumbnails" -> {
                val inputPath = call.argument<String>("inputPath")
                val count = call.argument<Int>("count") ?: 8
                if (inputPath.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "inputPath is required.", null)
                    return
                }
                generateVideoThumbnails(inputPath, count, result)
            }
            "fitToPortrait" -> {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "inputPath and outputPath are required.",
                        null,
                    )
                    return
                }
                renderPortraitVideo(inputPath, outputPath, result)
            }
            "exportWithTrim" -> {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val startMs = call.argument<Int>("startMs") ?: 0
                val endMs = call.argument<Int>("endMs") ?: 0
                val aspectRatio = call.argument<Double>("aspectRatio") ?: 1.0
                val audioVolume = call.argument<Double>("audioVolume") ?: 1.0
                val captionText = call.argument<String>("captionText").orEmpty()
                val captionColor = call.argument<Number>("captionColor")?.toInt() ?: 0xFFFFFFFF.toInt()
                val filter = call.argument<String>("filter") ?: "none"
                val arSticker = call.argument<String>("arSticker").orEmpty()
                val segments = call.argument<List<Map<String, Any?>>>("segments")
                    ?: emptyList()
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "inputPath and outputPath are required.",
                        null,
                    )
                    return
                }
                exportTrimmedVideo(
                    inputPath,
                    outputPath,
                    startMs,
                    endMs,
                    aspectRatio,
                    audioVolume,
                    captionText,
                    captionColor,
                    filter,
                    arSticker,
                    segments,
                    result,
                )
            }
            "saveToGallery" -> {
                val inputPath = call.argument<String>("inputPath")
                val title = call.argument<String>("title") ?: "edited_video"
                if (inputPath.isNullOrBlank()) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "inputPath is required.",
                        null,
                    )
                    return
                }
                saveVideoToGallery(inputPath, title, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun generateVideoThumbnails(
        inputPath: String,
        requestedCount: Int,
        result: MethodChannel.Result,
    ) {
        val inputFile = File(inputPath)
        if (!inputFile.isFile) {
            result.error("INPUT_NOT_FOUND", "The source video does not exist.", null)
            return
        }
        val count = requestedCount.coerceIn(1, 16)
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(inputFile.absolutePath)
                val durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?: 0L
                val outputDirectory = File(
                    cacheDir,
                    "video_thumbnails/${System.currentTimeMillis()}",
                ).apply { mkdirs() }
                val files = mutableListOf<String>()
                repeat(count) { index ->
                    val timeUs = if (durationMs <= 0L) {
                        0L
                    } else {
                        durationMs * 1000L * index / count
                    }
                    val bitmap = retriever.getFrameAtTime(
                        timeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    )
                    if (bitmap != null) {
                        val output = File(outputDirectory, "thumb_$index.jpg")
                        FileOutputStream(output).use { stream ->
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, stream)
                        }
                        bitmap.recycle()
                        files.add(output.absolutePath)
                    }
                }
                runOnUiThread { result.success(files) }
            } catch (failure: Exception) {
                runOnUiThread {
                    result.error(
                        "THUMBNAIL_FAILED",
                        failure.message ?: "Video thumbnails could not be generated.",
                        null,
                    )
                }
            } finally {
                retriever.release()
            }
        }.start()
    }

    private fun renderPortraitVideo(
        inputPath: String,
        outputPath: String,
        result: MethodChannel.Result,
    ) {
        if (activeTransformer != null) {
            result.error("EXPORT_BUSY", "A portrait video export is already running.", null)
            return
        }

        val inputFile = File(inputPath)
        if (!inputFile.isFile) {
            result.error("INPUT_NOT_FOUND", "The source video does not exist.", null)
            return
        }

        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists() && !outputFile.delete()) {
            result.error("OUTPUT_NOT_WRITABLE", "The old output file could not be replaced.", null)
            return
        }

        val portraitPresentation = Presentation.createForWidthAndHeight(
            720,
            1280,
            Presentation.LAYOUT_SCALE_TO_FIT,
        )
        val videoEffects: List<Effect> = listOf(portraitPresentation)
        val editedMediaItem = EditedMediaItem.Builder(
            MediaItem.fromUri(Uri.fromFile(inputFile)),
        ).setEffects(
            Effects(emptyList(), videoEffects),
        ).build()

        val transformer = Transformer.Builder(this)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(
                        composition: Composition,
                        exportResult: ExportResult,
                    ) {
                        finishPortraitExport(outputFile.absolutePath, null)
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finishPortraitExport(null, exportException)
                    }
                },
            )
            .build()

        activeTransformer = transformer
        activeResult = result
        try {
            transformer.start(editedMediaItem, outputFile.absolutePath)
        } catch (failure: Exception) {
            finishPortraitExport(null, failure)
        }
    }

    private fun exportTrimmedVideo(
        inputPath: String,
        outputPath: String,
        startMs: Int,
        endMs: Int,
        aspectRatio: Double,
        audioVolume: Double,
        captionText: String,
        captionColor: Int,
        filter: String,
        arSticker: String,
        rawSegments: List<Map<String, Any?>>,
        result: MethodChannel.Result,
    ) {
        val inputFile = File(inputPath)
        if (!inputFile.isFile) {
            result.error("INPUT_NOT_FOUND", "The source video does not exist.", null)
            return
        }

        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists() && !outputFile.delete()) {
            result.error("OUTPUT_NOT_WRITABLE", "The old output file could not be replaced.", null)
            return
        }

        val start = startMs.coerceIn(0, Int.MAX_VALUE)
        val end = endMs.coerceIn(0, Int.MAX_VALUE)
        val actualStart = if (end > start) start else 0
        val actualEnd = if (end > start) end else start

        // 들린 대사로 만든 시각별 자막. 손 자막이 있으면 얹지 않는다 — 자리가
        // 같아서 겹치면 읽을 수 없다.
        val subtitles = if (captionText.isBlank()) {
            SubtitleOverlay.of(rawSegments, captionColor)
        } else {
            null
        }

        val trimmedFile = File(outputPath)
        // 그릴 것이 있으면 복사로 빠질 수 없다.
        if (actualStart == 0 && actualEnd <= 0 &&
            captionText.isBlank() && arSticker.isBlank() && subtitles == null
        ) {
            inputFile.copyTo(trimmedFile, overwrite = true)
            result.success(trimmedFile.absolutePath)
            return
        }

        val normalizedRatio = aspectRatio.coerceIn(0.4, 2.5)
        val targetWidth: Int
        val targetHeight: Int
        if (normalizedRatio >= 1.0) {
            targetWidth = 1280
            targetHeight = ((1280 / normalizedRatio).roundToInt() / 2 * 2).coerceAtLeast(2)
        } else {
            targetHeight = 1280
            targetWidth = ((1280 * normalizedRatio).roundToInt() / 2 * 2).coerceAtLeast(2)
        }
        val presentation = Presentation.createForWidthAndHeight(
            targetWidth,
            targetHeight,
            Presentation.LAYOUT_SCALE_TO_FIT,
        )

        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(inputFile))
        if (actualStart > 0 || actualEnd > 0) {
            mediaItemBuilder.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(actualStart.toLong())
                    .setEndPositionMs(actualEnd.toLong())
                    .build(),
            )
        }

        val videoEffects = mutableListOf<Effect>(presentation)
        when (filter) {
            "mono" -> videoEffects.add(RgbFilter.createGrayscaleFilter())
            "warm" -> videoEffects.add(
                HslAdjustment.Builder()
                    .adjustHue(6f)
                    .adjustSaturation(12f)
                    .adjustLightness(3f)
                    .build(),
            )
            "vivid" -> videoEffects.add(
                HslAdjustment.Builder()
                    .adjustSaturation(28f)
                    .adjustLightness(4f)
                    .build(),
            )
        }

        val overlays = mutableListOf<TextureOverlay>()
        if (captionText.isNotBlank()) {
            val caption = SpannableString(captionText).apply {
                setSpan(
                    ForegroundColorSpan(captionColor),
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
            overlays.add(
                TextOverlay.createStaticTextOverlay(
                    caption,
                    StaticOverlaySettings.Builder()
                        .setBackgroundFrameAnchor(0f, -0.72f)
                        .build(),
                ),
            )
        }
        if (arSticker.isNotBlank()) {
            val sticker = SpannableString(arSticker).apply {
                setSpan(
                    AbsoluteSizeSpan(160),
                    0,
                    length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
            overlays.add(
                TextOverlay.createStaticTextOverlay(
                    sticker,
                    StaticOverlaySettings.Builder()
                        .setBackgroundFrameAnchor(0f, 0.28f)
                        .build(),
                ),
            )
        }
        subtitles?.let(overlays::add)
        if (overlays.isNotEmpty()) {
            videoEffects.add(OverlayEffect(overlays))
        }

        val audioProcessors = mutableListOf<AudioProcessor>()
        if (audioVolume < 0.999) {
            audioProcessors.add(
                GainProcessor(
                    DefaultGainProvider.Builder(audioVolume.toFloat().coerceIn(0f, 1f)).build(),
                ),
            )
        }

        val editedMediaItem = EditedMediaItem.Builder(
            mediaItemBuilder.build(),
        ).setEffects(Effects(audioProcessors, videoEffects)).build()

        val transformer = Transformer.Builder(this)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(
                        composition: Composition,
                        exportResult: ExportResult,
                    ) {
                        val output = File(outputPath)
                        if (output.exists() && output.length() > 0L) {
                            result.success(output.absolutePath)
                        } else {
                            result.error("EXPORT_EMPTY", "The exported file is empty.", null)
                        }
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        result.error(
                            "EXPORT_FAILED",
                            exportException.message ?: "The video could not be exported.",
                            null,
                        )
                    }
                },
            )
            .build()
        try {
            transformer.start(editedMediaItem, outputPath)
        } catch (failure: Exception) {
            result.error("EXPORT_FAILED", failure.message ?: "The video could not be exported.", null)
        }
    }

    private fun saveVideoToGallery(
        inputPath: String,
        title: String,
        result: MethodChannel.Result,
    ) {
        val inputFile = File(inputPath)
        if (!inputFile.isFile || inputFile.length() <= 0L) {
            result.error("INVALID_FILE", "The exported file is missing or empty.", null)
            return
        }

        try {
            val resolver = contentResolver
            val fileName = buildUniqueGalleryFileName(title)
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "Movies/${"WilliamJames"}")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
            }

            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)
            } else {
                resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)
            }
            if (uri == null) {
                result.error("GALLERY_INSERT_FAILED", "Could not create a gallery entry.", null)
                return
            }

            resolver.openOutputStream(uri)?.use { outputStream ->
                FileInputStream(inputFile).use { inputStream ->
                    inputStream.copyTo(outputStream)
                }
            } ?: run {
                result.error("GALLERY_WRITE_FAILED", "Could not write the video to the gallery.", null)
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentValues.clear()
                contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, contentValues, null, null)
            }

            result.success(uri.toString())
        } catch (failure: Exception) {
            result.error("GALLERY_SAVE_FAILED", failure.message ?: "Could not save the video to the gallery.", null)
        }
    }

    private fun buildUniqueGalleryFileName(title: String): String {
        val base = title.replace(Regex("[^a-zA-Z0-9가-힣._-]"), "_").takeIf { it.isNotBlank() } ?: "edited_video"
        val timestamp = System.currentTimeMillis()
        return "${base}_$timestamp.mp4"
    }

    private fun finishPortraitExport(
        outputPath: String?,
        failure: Exception?,
    ) {
        val result = activeResult
        activeTransformer = null
        activeResult = null
        if (result == null) return

        if (failure == null && outputPath != null) {
            result.success(outputPath)
        } else {
            result.error(
                "PORTRAIT_EXPORT_FAILED",
                failure?.message ?: "The portrait video could not be created.",
                null,
            )
        }
    }

    override fun onDestroy() {
        activeTransformer?.cancel()
        activeResult?.error(
            "EXPORT_CANCELLED",
            "The portrait video export was cancelled.",
            null,
        )
        activeTransformer = null
        activeResult = null
        super.onDestroy()
    }
}
