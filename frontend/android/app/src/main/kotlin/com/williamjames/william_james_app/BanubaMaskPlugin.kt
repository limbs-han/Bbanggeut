package com.williamjames.william_james_app

import android.app.Activity
import android.util.Log
import android.util.Size
import com.banuba.sdk.playback.VideoPlayerProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.koin.core.context.GlobalContext

/// AR 탭이 쓰는 네이티브 다리.
///
/// 편집기는 우리 것이고 Banuba는 **AR 탭이 빌려 쓰는 엔진**이다. 그래서 여기서
/// 하는 일은 넷뿐이다 — 엔진을 세우고, 영상을 물리고, 얼굴 마스크를 갈아 끼우고,
/// 저장할 때 그 마스크를 한 번 굽는다. Banuba 화면으로 넘어가는 길은 없다.
internal class BanubaMaskPlugin(private val activity: Activity) {
    companion object {
        private const val TAG = "BanubaMask"
    }

    private var preview: BanubaMaskPreview? = null
    private var events: EventChannel.EventSink? = null
    private val exporter = BanubaMaskExporter(activity)

    fun register(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            BanubaMaskContract.METHOD_CHANNEL,
        ).setMethodCallHandler(::handle)

        EventChannel(
            engine.dartExecutor.binaryMessenger,
            BanubaMaskContract.EVENT_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            },
        )

        engine.platformViewsController.registry.registerViewFactory(
            BanubaMaskContract.VIEW_TYPE,
            BanubaMaskPreviewFactory(
                onCreated = { created -> preview = created },
                onEvent = { event -> activity.runOnUiThread { events?.success(event) } },
            ),
        )
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            BanubaMaskContract.INITIALIZE -> initialize(call, result)
            BanubaMaskContract.AVAILABLE_MASKS ->
                result.success(BanubaMaskEffectHelper(activity).availableEffectCards())
            BanubaMaskContract.SET_VIDEO_SOURCE -> setVideoSource(call, result)
            BanubaMaskContract.PLAY -> withPreview(result) { it.play(); result.success(null) }
            BanubaMaskContract.PAUSE -> withPreview(result) { it.pause(); result.success(null) }
            BanubaMaskContract.SEEK_TO -> withPreview(result) {
                it.seekTo(call.argument<Int>(BanubaMaskContract.ARG_POSITION_MS) ?: 0)
                result.success(null)
            }
            BanubaMaskContract.APPLY_MASK -> applyMask(call, result)
            BanubaMaskContract.REMOVE_MASK -> applyMask(call, result, forceRemove = true)
            BanubaMaskContract.EXPORT -> export(call, result)
            BanubaMaskContract.CANCEL_EXPORT -> {
                exporter.cancel()
                result.success(null)
            }
            // AR 탭을 벗어난다. 세우기만 하지 않고 **놓아준다** — 멈춰 있어도
            // 효과 플레이어와 디코더 자리는 계속 쥐고 있어서, 곧바로 저장을
            // 누르면 굽는 쪽과 그 자리를 두고 다툰다.
            BanubaMaskContract.DISPOSE -> {
                preview?.releasePlayer()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private inline fun withPreview(
        result: MethodChannel.Result,
        block: (BanubaMaskPreview) -> Unit,
    ) {
        val current = preview
        if (current == null) {
            result.error(BanubaMaskContract.ERR_NO_PREVIEW, "미리보기가 아직 없어요.", null)
            return
        }
        block(current)
    }

    /// 엔진을 세운다. 여러 번 불러도 안전하다.
    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>(BanubaMaskContract.ARG_TOKEN).orEmpty()
        val failure = BanubaMaskRuntime.ensureReady(activity.application, token)
        if (failure != null) {
            Log.e(TAG, "runtime not ready: ${failure.code}")
            result.error(failure.code, failure.message, null)
            return
        }
        // 여기서 한 번 꺼내 보면, 바인딩이 비었을 때 화면을 그리기 전에 알 수 있다.
        val resolved = try {
            GlobalContext.getOrNull()?.get<VideoPlayerProvider>() != null
        } catch (failure: Throwable) {
            Log.e(TAG, "VideoPlayerProvider FAILED", failure)
            false
        }
        if (!resolved) {
            result.error(BanubaMaskContract.ERR_INIT, "AR 엔진을 준비하지 못했어요.", null)
            return
        }
        result.success(BanubaMaskEffectHelper(activity).availableEffectCards())
    }

    /// 저장할 때 마스크를 한 번 굽는다.
    ///
    /// 미리보기 없이도 돈다 — AR 탭을 떠난 뒤 저장을 눌러도 마스크가 빠지면
    /// 안 되기 때문이다. 그래서 화면이 아니라 [BanubaMaskRuntime]이 세워
    /// 놓은 엔진에 대고 부른다.
    private fun export(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>(BanubaMaskContract.ARG_TOKEN).orEmpty()
        val failure = BanubaMaskRuntime.ensureReady(activity.application, token)
        if (failure != null) {
            result.error(failure.code, failure.message, null)
            return
        }
        val rawRanges = call.argument<List<Map<String, Any?>>>(BanubaMaskContract.ARG_RANGES)
            ?: emptyList()
        val durationMs = (call.argument<Number>(BanubaMaskContract.ARG_DURATION_MS) ?: 0).toLong()
        val cuts = rawRanges.mapNotNull { range ->
            val start = (range[BanubaMaskContract.ARG_START_MS] as? Number)?.toLong() ?: return@mapNotNull null
            val end = (range[BanubaMaskContract.ARG_END_MS] as? Number)?.toLong() ?: return@mapNotNull null
            if (end <= start) null else BanubaMaskExporter.Cut(start, end)
        }
        val maskName = call.argument<String>(BanubaMaskContract.ARG_MASK_NAME).orEmpty()
        val outputPath = call.argument<String>(BanubaMaskContract.ARG_OUTPUT_PATH).orEmpty()
        val width = call.argument<Int>(BanubaMaskContract.ARG_WIDTH) ?: 0
        val height = call.argument<Int>(BanubaMaskContract.ARG_HEIGHT) ?: 0
        if (cuts.isEmpty() || maskName.isBlank() || outputPath.isBlank() || durationMs <= 0) {
            result.error(BanubaMaskContract.ERR_EXPORT, "마스크를 구울 정보가 모자라요.", null)
            return
        }

        val request = BanubaMaskExporter.Request(
            videoPath = call.argument<String>(BanubaMaskContract.ARG_VIDEO_PATH).orEmpty(),
            size = Size(if (width > 0) width else 720, if (height > 0) height else 1280),
            totalDurationMs = durationMs,
            cuts = cuts,
            maskName = maskName,
            outputPath = outputPath,
        )
        exporter.start(
            request,
            onProgress = { progress ->
                activity.runOnUiThread {
                    events?.success(
                        mapOf(
                            BanubaMaskContract.EVENT_TYPE to
                                BanubaMaskContract.EVENT_EXPORT_PROGRESS,
                            "progress" to progress,
                        ),
                    )
                }
            },
            onFinished = { outcome ->
                val path = outcome.path
                if (path != null) {
                    result.success(path)
                } else {
                    result.error(
                        outcome.code ?: BanubaMaskContract.ERR_EXPORT,
                        outcome.message ?: "마스크를 영상에 입히지 못했어요.",
                        null,
                    )
                }
            },
        )
    }

    private fun setVideoSource(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>(BanubaMaskContract.ARG_VIDEO_PATH).orEmpty()
        val width = call.argument<Int>(BanubaMaskContract.ARG_WIDTH) ?: 0
        val height = call.argument<Int>(BanubaMaskContract.ARG_HEIGHT) ?: 0
        val durationMs = (call.argument<Number>(BanubaMaskContract.ARG_DURATION_MS) ?: 0).toLong()
        val volume = (call.argument<Number>(BanubaMaskContract.ARG_VOLUME) ?: 1).toFloat()
        val startMs = (call.argument<Number>(BanubaMaskContract.ARG_START_MS) ?: 0).toLong()
        val endMs = (call.argument<Number>(BanubaMaskContract.ARG_END_MS) ?: 0).toLong()
        withPreview(result) { current ->
            val error = current.setVideoSource(
                path,
                Size(if (width > 0) width else 720, if (height > 0) height else 1280),
                durationMs,
                startMs,
                endMs,
                volume.coerceIn(0f, 1f),
            )
            if (error == null) result.success(null)
            else result.error(BanubaMaskContract.ERR_INIT, error, null)
        }
    }

    private fun applyMask(
        call: MethodCall,
        result: MethodChannel.Result,
        forceRemove: Boolean = false,
    ) {
        val name = if (forceRemove) {
            null
        } else {
            call.argument<String>(BanubaMaskContract.ARG_MASK_NAME)
        }
        withPreview(result) { current ->
            current.applyMask(name) { error ->
                if (error == null) {
                    result.success(null)
                } else {
                    result.error(BanubaMaskContract.ERR_EFFECT_MISSING, error, null)
                }
            }
        }
    }
}
