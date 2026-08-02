package com.williamjames.william_james_app

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import android.util.Size
import androidx.lifecycle.Observer
import com.banuba.sdk.core.AspectRatio
import com.banuba.sdk.core.VideoResolution
import com.banuba.sdk.core.domain.VideoSourceType
import com.banuba.sdk.effects.ve.VideoEffectsHelper
import com.banuba.sdk.export.data.DefaultExportErrorParser
import com.banuba.sdk.export.data.ExportError
import com.banuba.sdk.export.data.ExportErrorParser
import com.banuba.sdk.export.data.ExportFlowManager
import com.banuba.sdk.export.data.ExportParams
import com.banuba.sdk.export.data.ExportParamsProvider
import com.banuba.sdk.export.data.ExportResult
import com.banuba.sdk.export.data.ExportStopReason
import com.banuba.sdk.export.data.ExportTaskParams
import com.banuba.sdk.ve.domain.VideoRangeList
import com.banuba.sdk.ve.domain.VideoRecordRange
import com.banuba.sdk.ve.effects.Effects
import com.banuba.sdk.ve.effects.VisualTimedEffect
import com.banuba.sdk.ve.effects.music.MusicEffect
import org.koin.core.context.GlobalContext
import java.io.File
import java.util.UUID

/// 영상 한 조각을 Banuba에 넘기는 방식. 미리보기와 저장이 **같은 것**을 쓴다.
///
/// 인자 이름과 순서를 한 곳에만 적어 둔다. 양쪽에 흩어 놓으면 한쪽만 고쳤을 때
/// 미리보기에서 본 구간과 저장된 구간이 조용히 어긋난다.
internal fun banubaVideoRange(
    uri: Uri,
    totalMs: Long,
    startMs: Long,
    endMs: Long,
) = VideoRecordRange(
    mediaId = ParcelUuid(UUID.randomUUID()),
    durationMs = totalMs,
    speed = 1f,
    sourceUri = uri,
    playFromMs = startMs.coerceIn(0, totalMs),
    playToMs = if (endMs in 1..totalMs) endMs else totalMs,
    // 갤러리/서버에서 받은 파일이지 이 앱 카메라로 찍은 것이 아니다.
    type = VideoSourceType.GALLERY,
    pipApplied = false,
    containsAudio = true,
)

/// 저장할 때 얼굴 마스크를 **한 번만** 굽는다.
///
/// **왜 저장할 때인가**: 마스크는 프레임마다 얼굴을 찾아 그려야 해서 Banuba
/// 엔진만 할 수 있는 일이다. 미리보기는 그 엔진이 화면에 바로 그려 주지만,
/// 파일로 남기려면 따로 구워야 한다. 마스크를 고를 때마다 구우면 몇 번 눌러
/// 보는 것만으로 몇 분이 날아간다 — 그래서 저장을 누른 그 순간에 한 번만 한다.
///
/// **결과는 중간 파일이다.** 여기서 나온 영상이 기존 media3 파이프라인의 새
/// 원본이 되고, 컷·글자·스티커·색감·자막은 지금까지 하던 그대로 그쪽이 얹는다.
/// 마스크를 고르지 않았으면 이 길로 오지 않는다.
internal class BanubaMaskExporter(private val context: Context) {
    companion object {
        private const val TAG = "BanubaMask"
        private const val COVER_DIR = "banuba_mask"

        /// 화면 짧은 변을 기준으로 고른다. 최종 저장(EditorProjectExporter)이
        /// 긴 변을 1280으로 제한하므로, 여기서 그보다 크게 구워 봐야 곧바로
        /// 줄어들 뿐이다 — 시간만 두 배로 든다.
        private fun resolutionFor(size: Size): VideoResolution.Exact {
            val shortEdge = minOf(size.width, size.height)
            return when {
                shortEdge >= 720 -> VideoResolution.Exact.HD
                shortEdge >= 540 -> VideoResolution.Exact.QHD540
                shortEdge >= 480 -> VideoResolution.Exact.VGA480
                shortEdge >= 360 -> VideoResolution.Exact.VGA360
                else -> VideoResolution.Exact.VGA240
            }
        }
    }

    /// 굽고 싶은 것 하나.
    data class Request(
        val videoPath: String,
        val size: Size,
        val totalDurationMs: Long,
        /// 이어 붙일 구간들. 컷 편집이 정한 조각이 순서대로 온다.
        val cuts: List<Cut>,
        val maskName: String,
        val outputPath: String,
    )

    data class Cut(val startMs: Long, val endMs: Long)

    /// 끝났다. 성공이면 [path], 아니면 [code]와 [message].
    data class Outcome(
        val path: String? = null,
        val code: String? = null,
        val message: String? = null,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val effectHelper = BanubaMaskEffectHelper(context)

    private var flow: ExportFlowManager? = null
    private var observer: Observer<ExportResult>? = null
    private var request: Request? = null

    /// 얼마나 걸렸는지. 저장이 오래 걸릴 때 굽기와 media3 중 어느 쪽인지
    /// 로그만 보고 가릴 수 있어야 한다.
    private var startedAtMs: Long = 0

    /// SDK 진행률에서 빼야 하는 몫. [normalizeProgress] 설명 참고.
    private var progressOffset: Double = 0.0
    private var onProgress: ((Double) -> Unit)? = null
    private var onFinished: ((Outcome) -> Unit)? = null

    /// 굽기 시작한다. 이미 굽는 중이면 곧바로 실패로 알린다.
    ///
    /// 메인 스레드에서 부른다 — LiveData 구독이 그 스레드에서만 된다.
    fun start(
        request: Request,
        onProgress: (Double) -> Unit,
        onFinished: (Outcome) -> Unit,
    ) {
        if (this.onFinished != null) {
            onFinished(
                Outcome(
                    code = BanubaMaskContract.ERR_EXPORT,
                    message = "이미 마스크를 굽고 있어요.",
                ),
            )
            return
        }
        this.request = request
        this.onProgress = onProgress
        this.onFinished = onFinished

        // 효과 전개는 파일 복사라 첫 사용에서 수백 ms가 걸린다. 저장 버튼을
        // 누른 손이 화면에 붙잡히지 않도록 딴 실에서 편다.
        Thread {
            val effectUri = effectHelper.prepareEffect(request.maskName)
            handler.post {
                if (effectUri == null) {
                    finish(
                        Outcome(
                            code = BanubaMaskContract.ERR_EFFECT_MISSING,
                            message = "'${request.maskName}' 효과 파일을 찾지 못했어요.",
                        ),
                    )
                    return@post
                }
                begin(request, effectUri)
            }
        }.start()
    }

    /// 사용자가 그만뒀다. 실제 중단은 [ExportResult.Stopped]로 돌아온다.
    fun cancel() {
        flow?.stopExport(ExportStopReason.CANCEL)
    }

    private fun begin(request: Request, effectUri: Uri) {
        val source = File(request.videoPath)
        if (!source.isFile) {
            finish(
                Outcome(
                    code = BanubaMaskContract.ERR_EXPORT,
                    message = "영상 파일을 찾지 못했어요.",
                ),
            )
            return
        }
        val output = File(request.outputPath)
        val destination = output.parentFile
        if (destination == null || (!destination.isDirectory && !destination.mkdirs())) {
            finish(
                Outcome(
                    code = BanubaMaskContract.ERR_EXPORT,
                    message = "마스크를 구울 자리를 만들지 못했어요.",
                ),
            )
            return
        }

        val manager = try {
            GlobalContext.getOrNull()?.get<ExportFlowManager>()
        } catch (failure: Throwable) {
            // 바인딩이 비면 여기서 드러난다. 어느 것이 없는지는 로그에 남는다.
            Log.e(TAG, "no ExportFlowManager", failure)
            null
        }
        if (manager == null) {
            finish(
                Outcome(
                    code = BanubaMaskContract.ERR_EXPORT,
                    message = "AR 저장 준비를 하지 못했어요.",
                ),
            )
            return
        }

        val resolution = resolutionFor(request.size)
        BanubaMaskRuntime.exportParams.request = BanubaMaskExportParamsProvider.Request(
            destDir = destination,
            fileName = output.nameWithoutExtension,
            resolution = resolution,
        )

        val sourceUri = Uri.fromFile(source)
        val ranges = VideoRangeList(
            request.cuts.map { cut ->
                banubaVideoRange(sourceUri, request.totalDurationMs, cut.startMs, cut.endMs)
            },
        )
        val effects = Effects().apply {
            visualStack.push(
                VisualTimedEffect(
                    effectDrawable = VideoEffectsHelper.createMaskEffect(effectUri),
                ),
            )
        }

        // 지난번 결과가 LiveData에 남아 있다. 지우지 않으면 구독하는 순간 그
        // 값이 그대로 내려와 "시작하자마자 끝났다"가 된다.
        manager.setInactive()
        val watcher = Observer<ExportResult> { result -> onResult(result) }
        flow = manager
        observer = watcher
        manager.resultData.observeForever(watcher)

        startedAtMs = SystemClock.elapsedRealtime()
        val cutMs = request.cuts.sumOf { it.endMs - it.startMs }
        progressOffset = if (cutMs > 0) {
            request.cuts.first().startMs.toDouble() / cutMs
        } else {
            0.0
        }
        Log.d(
            TAG,
            "export start: ${request.cuts.size} range(s) = ${cutMs}ms, " +
                "$resolution, mask='${request.maskName}'",
        )
        try {
            manager.startExport(
                ExportTaskParams(
                    videoRanges = ranges,
                    effects = effects,
                    musicEffects = emptyList<MusicEffect>(),
                    // 소리는 원본 그대로 넘긴다. 볼륨·음소거는 최종 저장에서
                    // media3가 정한다 — 두 곳에서 곱하면 두 번 줄어든다.
                    videoVolume = 1f,
                    // 표지 그림을 **우리가 준다.**
                    //
                    // 비워 두면(`Uri.EMPTY`) SDK가 표지를 만들려고
                    // `CoverFrameExtractor`로 **두 번째 Face AR 렌더링**을 띄운다 —
                    // 본 내보내기와 나란히 돌면서 같은 디코더와 효과 플레이어를
                    // 두고 다툰다. 그 작업은 본 내보내기와 마지막에 합쳐지므로,
                    // 표지 쪽이 일찍 죽어도 오류는 렌더링이 다 끝난 뒤에야
                    // 나타난다(2분 갈아 넣고 "마스크를 씌우지 못했습니다").
                    //
                    // 우리는 표지를 쓰지 않는다. 최종 파일은 media3가 만들고
                    // 목록 그림은 앱이 따로 뽑는다. 그래서 읽을 수 있는 그림
                    // 하나만 쥐여 주고 그 경로를 통째로 건너뛴다.
                    coverUri = placeholderCover(),
                    coverFrameSize = request.size,
                    aspect = AspectRatio(
                        if (request.size.height > 0) {
                            request.size.width.toDouble() / request.size.height
                        } else {
                            0.0
                        },
                    ),
                    videoResolution = resolution,
                    // 초안(draft)은 쓰지 않지만 인자에 기본값이 없다. 매번 새
                    // 값을 준다 — 이 굽기는 저장 한 번으로 끝나고 남지 않는다.
                    draftUuid = ParcelUuid(UUID.randomUUID()),
                ),
            )
        } catch (failure: Throwable) {
            Log.e(TAG, "startExport threw", failure)
            detach()
            finish(
                Outcome(
                    code = BanubaMaskContract.ERR_EXPORT,
                    message = "마스크를 굽기 시작하지 못했어요.",
                ),
            )
        }
    }

    /// 표지 자리를 채울 1×1 그림. 한 번 만들어 두고 계속 쓴다.
    ///
    /// 만들지 못하면 빈 Uri로 돌아간다 — 그러면 SDK가 예전처럼 자기가 표지를
    /// 뽑는다. 표지 하나 때문에 저장 자체를 막지는 않는다.
    private fun placeholderCover(): Uri {
        val file = File(File(context.cacheDir, COVER_DIR), "cover.png")
        if (file.isFile && file.length() > 0) return Uri.fromFile(file)
        return try {
            file.parentFile?.mkdirs()
            val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
            try {
                file.outputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
            } finally {
                bitmap.recycle()
            }
            Uri.fromFile(file)
        } catch (failure: Throwable) {
            Log.w(TAG, "no placeholder cover: ${failure.javaClass.simpleName}")
            Uri.EMPTY
        }
    }

    /// 시작한 지 얼마나 됐나. 로그에만 쓴다.
    private fun elapsed(): Long = SystemClock.elapsedRealtime() - startedAtMs

    /// SDK가 주는 진행률을 0~1로 바로잡는다.
    ///
    /// **SDK 쪽이 어긋나 있다.** `ExportTask`는 지금 쓰고 있는 프레임의 **원본
    /// 시각**을 잘라낸 길이로 나눈다(`ExportTask.processExport$lambda$6`).
    /// 원본 시각은 구간 시작(`playFrom`)부터 세는데 나누는 값은 구간 **길이**라,
    /// 앞을 잘라낸 영상에서는 시작하자마자 큰 값이 나오고 끝날 때 100을 넘는다.
    /// 실제로 60089..127912(67823ms) 구간에서 89%로 시작해 189%로 끝났다 —
    /// 화면의 진행 막대는 14초 만에 꽉 차고 남은 3분을 그대로 서 있었다.
    ///
    /// 시작점이 차지하는 몫만 빼면 제자리로 온다. 자르지 않은 영상은 그 몫이
    /// 0이라 지금까지와 똑같이 동작한다. 조각이 여럿이면 SDK가 이어 붙이며
    /// 값을 쌓아서 정확히 맞지는 않는다 — 그때는 잘라내기만 한다.
    private fun normalizeProgress(percentage: Int): Double =
        (percentage / 100.0 - progressOffset).coerceIn(0.0, 1.0)

    private fun onResult(result: ExportResult) {
        when (result) {
            is ExportResult.Progress ->
                onProgress?.invoke(normalizeProgress(result.percentage))

            is ExportResult.Success -> {
                Log.d(TAG, "export done in ${elapsed()}ms")
                detach()
                deliver(result)
            }

            is ExportResult.Error -> {
                Log.w(TAG, "export failed after ${elapsed()}ms: ${result.type}")
                detach()
                finish(
                    Outcome(
                        code = BanubaMaskContract.ERR_EXPORT,
                        message = "마스크를 영상에 입히지 못했어요. (${result.type})",
                    ),
                )
            }

            is ExportResult.Stopped -> {
                detach()
                finish(
                    Outcome(
                        code = BanubaMaskContract.ERR_EXPORT_CANCELLED,
                        message = "마스크 굽기를 그만뒀어요.",
                    ),
                )
            }

            // 방금 우리가 지운 값이다. 아무 일도 아니다.
            else -> Unit
        }
    }

    /// 구워진 파일을 우리가 약속한 자리로 옮긴다.
    ///
    /// 파일 이름은 우리가 정했지만 확장자까지는 Banuba가 붙인다. 그래서 결과
    /// URI를 받아 확인하고, 자리가 다르면 그때만 옮긴다(같은 폴더 안이라
    /// 이름만 바뀐다).
    private fun deliver(result: ExportResult.Success) {
        val target = request?.outputPath
        val produced = result.videoList.firstOrNull()?.sourceUri?.path
        if (target == null || produced.isNullOrBlank()) {
            finish(
                Outcome(
                    code = BanubaMaskContract.ERR_EXPORT,
                    message = "마스크를 입힌 영상을 찾지 못했어요.",
                ),
            )
            return
        }
        val source = File(produced)
        val destination = File(target)
        if (source.absolutePath == destination.absolutePath) {
            finish(Outcome(path = target))
            return
        }
        Thread {
            val moved = try {
                if (destination.exists()) destination.delete()
                source.renameTo(destination) || run {
                    source.copyTo(destination, overwrite = true)
                    source.delete()
                    true
                }
            } catch (failure: Throwable) {
                Log.e(TAG, "cannot move export result", failure)
                false
            }
            handler.post {
                finish(
                    if (moved) {
                        Outcome(path = target)
                    } else {
                        Outcome(
                            code = BanubaMaskContract.ERR_EXPORT,
                            message = "마스크를 입힌 영상을 옮기지 못했어요.",
                        )
                    },
                )
            }
        }.start()
    }

    private fun detach() {
        val watcher = observer
        val manager = flow
        observer = null
        flow = null
        if (watcher != null && manager != null) {
            manager.resultData.removeObserver(watcher)
        }
    }

    /// 한 번만 알린다. 실패했으면 반쯤 만들어진 파일을 남기지 않는다.
    private fun finish(outcome: Outcome) {
        detach()
        BanubaMaskRuntime.exportParams.request = null
        val notify = onFinished
        val target = request?.outputPath
        onFinished = null
        onProgress = null
        request = null
        if (outcome.path == null && target != null) {
            runCatching { File(target).delete() }
        }
        notify?.invoke(outcome)
    }
}

/// 마스크를 구울 때 쓸 내보내기 설정.
///
/// **왜 SDK 기본값을 쓰지 않는가**: 기본 `SimpleExportParamsProvider`는 결과를
/// SDK가 정한 폴더에 SDK가 지은 이름으로 넣고, 해상도도 기기가 "적당하다"고
/// 답하는 값에 맡긴다. 우리는 그 파일을 곧바로 media3에 넘겨야 해서 어디에
/// 무슨 이름으로 놓였는지 알아야 하고, 해상도도 최종 저장이 남길 크기에
/// 맞춰야 두 번 인코딩하면서 화질만 깎는 일이 없다. 워터마크 경로도 지나가지
/// 않는다 — 우리 영상에 남의 로고를 얹을 이유가 없다.
///
/// 굽기는 한 번에 하나뿐이라(저장 버튼이 잠긴다) 요청을 하나만 들고 있는다.
internal class BanubaMaskExportParamsProvider : ExportParamsProvider {
    data class Request(
        val destDir: File,
        val fileName: String,
        val resolution: VideoResolution.Exact,
    )

    @Volatile
    var request: Request? = null

    override fun provideExportParams(
        effects: Effects,
        videoRangeList: VideoRangeList,
        musicEffects: List<MusicEffect>,
        videoVolume: Float,
    ): List<ExportParams> {
        val current = request
            ?: error("BanubaMaskExporter가 요청을 넣기 전에 내보내기가 시작됐어요.")
        current.destDir.mkdirs()
        return listOf(
            ExportParams.Builder(current.resolution)
                .effects(effects)
                .videoRangeList(videoRangeList)
                .musicEffects(musicEffects)
                .volumeVideo(videoVolume)
                .fileName(current.fileName)
                .destDir(current.destDir)
                .build(),
        )
    }
}

/// 내보내기가 왜 죽었는지 **로그에 남긴다.**
///
/// `ExportFlowManager`가 올려 주는 것은 `ExportError` 하나뿐이라
/// `EXPORT_RESULT_ERROR`처럼 다섯 가지 예외가 한 이름으로 뭉쳐 온다. 어느
/// 것인지 알 길이 없어 기기에서만 나는 실패를 쫓을 수 없다. 분류는 SDK 기본
/// 구현에 그대로 맡기고, 지나가는 예외만 우리 태그로 찍는다.
internal object BanubaMaskExportErrorParser : ExportErrorParser {
    private val fallback = DefaultExportErrorParser()

    override fun parse(t: Throwable?): ExportError {
        Log.e("BanubaMask", "export threw", t)
        return fallback.parse(t)
    }
}

/// 표지 그림은 굽지 않는다.
///
/// 이 바인딩은 원래 Banuba 편집기 화면 모듈(`VeFlowKoinModule`)만 내놓는다.
/// 우리는 그 화면으로 가지 않으므로 그 모듈을 세우지 않고, 대신 내보내기가
/// 물어보는 이 하나만 채운다. 표지는 편집기 화면의 기능이고 우리에게는 없다.
internal object BanubaMaskCoverNotInExport :
    com.banuba.sdk.export.internal.CoverContainsInExport {
    override fun contains(): Boolean = false
}
