package com.williamjames.william_james_app

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Typeface
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
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
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

@UnstableApi
class MainActivity : FlutterActivity() {
    companion object {
        private const val VIDEO_CANVAS_CHANNEL = "com.williamjames/video_canvas"

        /// 타임라인 썸네일의 세로 픽셀 수.
        ///
        /// 띠는 화면에서 50~80dp다. 3배 밀도라도 144px이면 또렷하고, 192px보다
        /// 디코딩·축소·JPEG 압축이 모두 가벼워 편집 진입이 그만큼 빨라진다.
        private const val THUMBNAIL_HEIGHT = 144

        /// 썸네일 JPEG 품질. 손톱만 한 그림이라 60과 75는 눈으로 구분되지
        /// 않는데 파일 크기와 압축 시간은 눈에 띄게 차이 난다.
        private const val THUMBNAIL_QUALITY = 60

        /// 프레임을 나눠 뽑을 스레드 수의 상한. 더 늘리면 하드웨어 디코더를
        /// 두고 서로 기다린다.
        private const val THUMBNAIL_WORKERS = 4

        /// 뽑아 둔 프레임을 모아 두는 캐시 폴더.
        private const val THUMBNAIL_CACHE_DIRECTORY = "video_thumbnails"

        /// 캐시에 남겨 둘 영상 수. 최근에 쓴 것부터 센다.
        private const val THUMBNAIL_CACHE_KEEP = 6

        /// 갤러리로 옮길 때 한 번에 밀어 넣는 크기.
        private const val COPY_CHUNK_BYTES = 8L * 1024 * 1024
    }

    private var activeTransformer: Transformer? = null
    private var activeResult: MethodChannel.Result? = null
    private lateinit var editorProjectExporter: EditorProjectExporter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        editorProjectExporter = EditorProjectExporter(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VIDEO_CANVAS_CHANNEL,
        ).setMethodCallHandler(::handleVideoCanvasCall)
        SttChannel.register(flutterEngine, this)
    }

    /**
     * 자막용 마이크 권한 응답을 [MicPermission]에 넘긴다. ML Kit 음성 인식이
     * 파일 입력인데도 RECORD_AUDIO를 요구해서 물어봐야 한다.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (MicPermission.handleResult(requestCode, grantResults)) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun handleVideoCanvasCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (editorProjectExporter.handles(call.method)) {
            editorProjectExporter.handle(call, result)
            return
        }
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
            try {
                val files = extractThumbnails(inputFile, count)
                runOnUiThread { result.success(files) }
            } catch (failure: Exception) {
                runOnUiThread {
                    result.error(
                        "THUMBNAIL_FAILED",
                        failure.message ?: "Video thumbnails could not be generated.",
                        null,
                    )
                }
            }
        }.start()
    }

    /// 타임라인 띠에 깔 프레임을 뽑는다.
    ///
    /// 예전에는 한 스레드가 원본 해상도 그대로 여덟 장을 순서대로 디코딩하고
    /// 그 큰 비트맵을 JPEG로 구웠다. 1080p 영상에서는 이 과정만으로 편집
    /// 화면의 타임라인이 몇 초 동안 비어 있었다. 두 가지를 바꿨다.
    ///
    /// - 필요한 크기로 바로 받는다(`getScaledFrameAtTime`). 만들었다 버리는
    ///   큰 비트맵이 없어져 디코딩과 압축 비용이 같이 줄어든다.
    /// - 일꾼 몇을 두고 나눠 맡는다. MediaMetadataRetriever는 스레드마다
    ///   따로 있어야 하므로 각자 자기 것을 연다.
    /// - **한 번 뽑은 지점은 다시 뽑지 않는다.** 예전에는 부를 때마다 시각
    ///   (`currentTimeMillis`)으로 새 폴더를 만들었다. 그래서 (1) 편집기를 닫고
    ///   다시 열면 이미 뽑아 둔 그림이 있는데도 처음부터 다시 디코딩했고,
    ///   (2) 띠를 성긴 것 → 촘촘한 것으로 두 번 채우는 동안 겹치는 지점을 두 번
    ///   뽑았고(4+12=16장을 뽑아 12장을 썼다), (3) 쓰고 버린 폴더가 지워지지
    ///   않아 캐시만 쌓였다.
    private fun extractThumbnails(inputFile: File, count: Int): List<String> {
        // 폴더는 영상마다, 파일은 **영상에서 몇 분의 몇 지점인가**로 정한다.
        // 파일이 바뀌면(수정 시각) 폴더 이름도 바뀌므로 낡은 그림이 되살아날
        // 일은 없다.
        val root = File(cacheDir, THUMBNAIL_CACHE_DIRECTORY)
        val outputDirectory = File(root, thumbnailCacheKey(inputFile))
        val wanted = (0 until count).map {
            File(outputDirectory, thumbnailName(it, count))
        }
        if (wanted.all { it.isFile && it.length() > 0L }) {
            // 최근에 쓴 것으로 표시해 둔다. 오래된 것부터 걷어내기 때문이다.
            // 여기서는 영상 길이를 읽을 일조차 없다.
            outputDirectory.setLastModified(System.currentTimeMillis())
            return wanted.map { it.absolutePath }
        }

        val probe = MediaMetadataRetriever()
        val durationMs: Long
        val sourceWidth: Int
        val sourceHeight: Int
        try {
            probe.setDataSource(inputFile.absolutePath)
            durationMs = probe
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: 0L
            sourceWidth = probe
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull()
                ?: 0
            sourceHeight = probe
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull()
                ?: 0
        } finally {
            probe.release()
        }

        val targetWidth = if (sourceWidth > 0 && sourceHeight > 0) {
            (THUMBNAIL_HEIGHT.toLong() * sourceWidth / sourceHeight)
                .toInt()
                .coerceIn(2, THUMBNAIL_HEIGHT * 4)
        } else {
            THUMBNAIL_HEIGHT * 16 / 9
        }

        outputDirectory.mkdirs()
        val paths = arrayOfNulls<String>(count)
        val nextIndex = AtomicInteger(0)
        // 코어가 적은 기기에서 일꾼을 다 띄우면 UI 스레드까지 굶는다.
        val workerCount = minOf(
            THUMBNAIL_WORKERS,
            count,
            maxOf(2, Runtime.getRuntime().availableProcessors() / 2),
        )
        val workers = (0 until workerCount).map {
            Thread {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(inputFile.absolutePath)
                    while (true) {
                        val index = nextIndex.getAndIncrement()
                        if (index >= count) break
                        val output = wanted[index]
                        // 성긴 묶음이 이미 뽑아 둔 지점이면 그걸 그대로 쓴다.
                        if (output.isFile && output.length() > 0L) {
                            paths[index] = output.absolutePath
                            continue
                        }
                        val timeUs = if (durationMs <= 0L) {
                            0L
                        } else {
                            durationMs * 1000L * index / count
                        }
                        val bitmap = retriever.scaledFrameAt(
                            timeUs,
                            targetWidth,
                            THUMBNAIL_HEIGHT,
                        ) ?: continue
                        FileOutputStream(output).use { stream ->
                            bitmap.compress(
                                Bitmap.CompressFormat.JPEG,
                                THUMBNAIL_QUALITY,
                                stream,
                            )
                        }
                        bitmap.recycle()
                        paths[index] = output.absolutePath
                    }
                } catch (ignored: Exception) {
                    // 한 일꾼이 넘어져도 나머지가 뽑아 둔 프레임은 그대로 쓴다.
                    // 타임라인은 빈 칸을 견딘다.
                } finally {
                    retriever.release()
                }
            }
        }
        workers.forEach(Thread::start)
        workers.forEach(Thread::join)
        pruneThumbnailCache(root)
        return paths.filterNotNull()
    }

    /// 영상 하나의 자리. 파일이 바뀌면 자리도 바뀐다.
    ///
    /// 길이를 이름에 함께 넣는다. 해시는 32비트뿐이라 서로 다른 영상이 같은
    /// 자리를 잡을 수 있는데, 그러면 엉뚱한 영상의 프레임이 띠에 깔린다.
    private fun thumbnailCacheKey(inputFile: File): String {
        val hash = "${inputFile.absolutePath}:${inputFile.lastModified()}"
            .hashCode()
            .toUInt()
            .toString(16)
        return "${hash}_${inputFile.length()}"
    }

    /// 프레임 하나의 이름. `index / count`를 **기약분수로 줄여** 붙인다.
    ///
    /// **왜 분수인가**: 띠는 4장으로 먼저 채우고 12장으로 갈아 끼운다. 4장의
    /// 1/4과 12장의 3/12은 영상에서 같은 지점이다. 이름을 `thumb_1`,
    /// `thumb_3`처럼 순번으로 붙이면 그게 같은 지점인 줄 모르고 다시 디코딩한다.
    /// 줄인 분수로 붙이면 둘 다 `frame_1_4`가 되어, 촘촘한 묶음은 겹치는 네 장을
    /// 건너뛰고 여덟 장만 뽑는다.
    private fun thumbnailName(index: Int, count: Int): String {
        val divisor = greatestCommonDivisor(index, count)
        return "frame_${index / divisor}_${count / divisor}.jpg"
    }

    private fun greatestCommonDivisor(a: Int, b: Int): Int {
        var left = a
        var right = b
        while (right != 0) {
            val remainder = left % right
            left = right
            right = remainder
        }
        return if (left == 0) 1 else left
    }

    /// 오래 쓰지 않은 묶음을 걷어낸다. 캐시가 한없이 늘지 않게 한다.
    private fun pruneThumbnailCache(root: File) {
        val directories = root.listFiles()?.filter { it.isDirectory } ?: return
        if (directories.size <= THUMBNAIL_CACHE_KEEP) return
        directories
            .sortedByDescending { it.lastModified() }
            .drop(THUMBNAIL_CACHE_KEEP)
            .forEach { it.deleteRecursively() }
    }

    private fun MediaMetadataRetriever.scaledFrameAt(
        timeUs: Long,
        width: Int,
        height: Int,
    ) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
        getScaledFrameAtTime(
            timeUs,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            width,
            height,
        )
    } else {
        getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
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

        Thread {
            // 안드로이드 9 이하에는 MediaStore RELATIVE_PATH가 없다. 공용
            // Movies 폴더에 직접 쓰고 미디어 스캐너에 알린다.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                saveToLegacyGallery(inputFile, title, result)
                return@Thread
            }
            val resolver = contentResolver
            var uri: Uri? = null
            try {
                val fileName = buildUniqueGalleryFileName(title)
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.MediaColumns.RELATIVE_PATH, "Movies/WilliamJames")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                }

                val insertedUri = resolver.insert(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    contentValues,
                ) ?: throw IllegalStateException("Could not create a gallery entry.")
                uri = insertedUri

                resolver.openOutputStream(insertedUri)?.use { outputStream ->
                    copyFast(inputFile, outputStream)
                } ?: throw IllegalStateException("Could not write the video to the gallery.")

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    contentValues.clear()
                    contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(insertedUri, contentValues, null, null)
                }

                runOnUiThread { result.success(insertedUri.toString()) }
            } catch (failure: Exception) {
                uri?.let {
                    try {
                        resolver.delete(it, null, null)
                    } catch (_: Exception) {
                        // The original save error is more useful to Flutter.
                    }
                }
                runOnUiThread {
                    result.error(
                        "GALLERY_SAVE_FAILED",
                        failure.message ?: "Could not save the video to the gallery.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun saveToLegacyGallery(
        inputFile: File,
        title: String,
        result: MethodChannel.Result,
    ) {
        try {
            val galleryDirectory = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                "WilliamJames",
            )
            if (!galleryDirectory.isDirectory && !galleryDirectory.mkdirs()) {
                throw IllegalStateException("Could not create the gallery folder.")
            }
            val destination = File(galleryDirectory, buildUniqueGalleryFileName(title))
            FileOutputStream(destination).use { outputStream ->
                copyFast(inputFile, outputStream)
            }
            // 스캐너에 알리지 않으면 갤러리 앱 목록에 뜨지 않는다.
            MediaScannerConnection.scanFile(
                this,
                arrayOf(destination.absolutePath),
                arrayOf("video/mp4"),
                null,
            )
            runOnUiThread { result.success(destination.absolutePath) }
        } catch (failure: Exception) {
            runOnUiThread {
                result.error(
                    "GALLERY_SAVE_FAILED",
                    failure.message ?: "Could not save the video to the gallery.",
                    null,
                )
            }
        }
    }

    /// 편집 결과를 갤러리로 옮긴다.
    ///
    /// MediaStore가 주는 스트림은 대개 파일 디스크립터를 감싼 것이라 커널이
    /// 바로 옮길 수 있다. 128KiB씩 사용자 공간을 오가며 복사하던 예전 방식보다
    /// 큰 영상에서 눈에 띄게 빠르다. 파일이 아닌 스트림이 오면 예전처럼 버퍼로
    /// 복사한다.
    private fun copyFast(source: File, destination: OutputStream) {
        FileInputStream(source).use { input ->
            val sink = (destination as? FileOutputStream)?.channel
            if (sink == null) {
                input.copyTo(destination, 1 shl 20)
                return
            }
            val channel = input.channel
            val size = channel.size()
            var position = 0L
            while (position < size) {
                val moved = channel.transferTo(
                    position,
                    minOf(COPY_CHUNK_BYTES, size - position),
                    sink,
                )
                if (moved <= 0L) break
                position += moved
            }
            if (position < size) {
                // transferTo가 더 못 옮기는 상황(파이프 등)에서는 남은 만큼만
                // 버퍼로 마저 채운다.
                channel.position(position)
                input.copyTo(destination, 1 shl 20)
            }
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
        if (::editorProjectExporter.isInitialized) {
            editorProjectExporter.dispose()
        }
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
