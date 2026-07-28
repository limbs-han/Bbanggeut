package com.williamjames.william_james_app

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
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
    }

    private fun handleVideoCanvasCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
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
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "inputPath and outputPath are required.",
                        null,
                    )
                    return
                }
                exportTrimmedVideo(inputPath, outputPath, startMs, endMs, aspectRatio, result)
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

        val trimmedFile = File(outputPath)
        if (actualStart == 0 && actualEnd <= 0) {
            inputFile.copyTo(trimmedFile, overwrite = true)
            result.success(trimmedFile.absolutePath)
            return
        }

        val presentation = if (aspectRatio > 1.0) {
            Presentation.createForWidthAndHeight(1280, 720, Presentation.LAYOUT_SCALE_TO_FIT)
        } else {
            Presentation.createForWidthAndHeight(720, 1280, Presentation.LAYOUT_SCALE_TO_FIT)
        }

        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(inputFile))
        if (actualStart > 0 || actualEnd > 0) {
            mediaItemBuilder.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(actualStart.toLong())
                    .setEndPositionMs(actualEnd.toLong())
                    .build(),
            )
        }

        val editedMediaItem = EditedMediaItem.Builder(
            mediaItemBuilder.build(),
        ).setEffects(Effects(emptyList(), listOf(presentation))).build()

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
