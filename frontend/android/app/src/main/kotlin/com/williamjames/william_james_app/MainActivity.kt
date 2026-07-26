package com.williamjames.william_james_app

import android.net.Uri
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
        if (call.method != "fitToPortrait") {
            result.notImplemented()
            return
        }

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
