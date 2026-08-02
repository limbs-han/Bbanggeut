package com.williamjames.william_james_app

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import com.banuba.sdk.effects.ve.VideoEffectsHelper
import com.banuba.sdk.playback.PlaybackError
import com.banuba.sdk.playback.PlayerScaleType
import com.banuba.sdk.playback.PlayerState
import com.banuba.sdk.playback.VideoPlayer
import com.banuba.sdk.playback.VideoPlayerProvider
import com.banuba.sdk.ve.effects.Effects
import com.banuba.sdk.ve.effects.VisualTimedEffect
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.koin.core.context.GlobalContext
import java.io.File

/// 편집 화면 **안**에 박히는 Banuba 미리보기.
///
/// 화면을 옮기지 않고 얼굴 마스크를 바로 보여 주려면 프레임 합성이 필요하고,
/// 그건 Banuba 플레이어만 할 수 있다. 그래서 AR 탭에 있는 동안에만 이 뷰가
/// 재생을 맡는다 — 탭을 벗어나면 Flutter 쪽 재생기로 돌아간다. 두 재생기가
/// 동시에 소리를 내지 않도록 전환은 Dart 쪽에서 한 줄기로 관리한다.
internal class BanubaMaskPreview(
    context: Context,
    private val onEvent: (Map<String, Any?>) -> Unit,
) : PlatformView, SurfaceHolder.Callback {
    companion object {
        private const val TAG = "BanubaMask"
    }

    private val surface = SurfaceView(context)
    private val handler = Handler(Looper.getMainLooper())
    private val effectHelper = BanubaMaskEffectHelper(context)

    private var provider: VideoPlayerProvider? = null
    private var player: VideoPlayer? = null
    private var sourceUri: Uri? = null
    private var durationMs: Long = 0
    private var appliedMask: String? = null

    /// 마스크를 빠르게 여러 번 누를 때 뒤늦게 끝난 준비가 최신 선택을 덮지
    /// 않게 하는 표. 누를 때마다 올린다.
    private var maskGeneration = 0

    /// 재생 위치와 상태는 **플레이어가 알려 준다**. `VideoPlayer`에는 위치를
    /// 물어보는 함수가 없어서(인터페이스에 getter가 없다) 이 콜백이 유일한
    /// 통로다 — 폴링으로 흉내 낼 수 없다.
    private val playerCallback = object : VideoPlayer.Callback {
        override fun onVideoPositionChanged(position: Int) {
            onEvent(
                mapOf(
                    BanubaMaskContract.EVENT_TYPE to BanubaMaskContract.EVENT_POSITION,
                    "positionMs" to position,
                ),
            )
        }

        override fun onPlayStateChanged(state: PlayerState) {
            // 플레이어가 주는 상태는 넷뿐이다(IDLE·LOADING·PLAYING·FINISHED).
            // "멈춤"은 따로 없어서 IDLE로 온다 — 우리 쪽 정지와 같은 뜻으로 쓴다.
            emitState(
                when (state) {
                    PlayerState.PLAYING -> BanubaMaskContract.STATE_PLAYING
                    PlayerState.LOADING -> BanubaMaskContract.STATE_PREPARING
                    PlayerState.FINISHED -> BanubaMaskContract.STATE_COMPLETED
                    else -> BanubaMaskContract.STATE_PAUSED
                },
            )
        }

        override fun onVideoPlaybackError(error: PlaybackError) {
            Log.w(TAG, "playback error: $error")
            onEvent(
                mapOf(
                    BanubaMaskContract.EVENT_TYPE to BanubaMaskContract.EVENT_ERROR,
                    "message" to "미리보기 재생 중 문제가 생겼어요.",
                ),
            )
        }
    }

    init {
        surface.holder.addCallback(this)
    }

    override fun getView(): View = surface

    override fun dispose() = releasePlayer()

    /// 플레이어와 그것이 쥔 GL·디코더 자리를 놓아준다. 여러 번 불러도 안전하다.
    ///
    /// **왜 화면이 사라지기 전에도 부를 수 있어야 하나**: 저장할 때 마스크를
    /// 굽는 쪽([BanubaMaskExporter])도 같은 효과 플레이어와 하드웨어 디코더를
    /// 쓴다. 미리보기가 자리를 쥔 채로 굽기 시작하면 둘이 다투다 눈에 띄게
    /// 느려진다. 플랫폼 뷰가 트리에서 빠지는 건 다음 프레임이라 늦으므로,
    /// AR 탭을 벗어나는 그 자리에서 놓는다.
    fun releasePlayer() {
        val active = player
        player = null
        if (active != null) {
            try {
                active.clearSurfaceHolder(surface.holder)
                provider?.releaseInstance(active)
            } catch (failure: Throwable) {
                Log.w(TAG, "release failed: ${failure.javaClass.simpleName}")
            }
        }
        // 전역 SDK는 내리지 않는다. 화면이 닫히는 것과 SDK가 끝나는 것은 다르다.
        provider = null
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        player?.setSurfaceHolder(holder)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        player?.clearSurfaceHolder(holder)
    }

    /// 영상을 물린다. 플레이어는 **한 번만** 만들고, 이후에는 효과만 갈아 끼운다.
    fun setVideoSource(
        path: String,
        size: Size,
        totalMs: Long,
        startMs: Long,
        endMs: Long,
        volume: Float,
    ): String? {
        val file = File(path)
        if (!file.isFile) return "영상 파일을 찾지 못했어요."
        sourceUri = Uri.fromFile(file)
        durationMs = totalMs

        val koin = GlobalContext.getOrNull()
            ?: return "Banuba 준비가 끝나지 않았어요."
        val playerProvider = try {
            koin.get<VideoPlayerProvider>()
        } catch (failure: Throwable) {
            Log.e(TAG, "no VideoPlayerProvider", failure)
            return "미리보기 플레이어를 만들지 못했어요."
        }
        provider = playerProvider

        val active = try {
            playerProvider.getInstance(size, true)
        } catch (failure: Throwable) {
            Log.e(TAG, "getInstance failed", failure)
            return "미리보기 플레이어를 만들지 못했어요."
        }
        player = active

        return try {
            // prepare가 false면 예외 없이 조용히 아무것도 그려지지 않는다.
            // 그때만 남긴다 — 화면이 검을 때 여기부터 보면 된다.
            if (!active.prepare(size, true)) {
                Log.w(TAG, "prepare($size) returned false")
            }
            active.setScaleType(PlayerScaleType.FIT_SCREEN_HEIGHT)
            // 소리를 켠다. 기본값이 0이라 이걸 빼면 화면만 돌고 조용하다.
            active.setVolume(volume)
            active.setCallback(playerCallback)
            active.setSurfaceHolder(surface.holder)
            // 컷 편집에서 정한 구간만 담는다.
            //
            // **왜 구간을 넘기나**: 예전에는 원본 전체를 통째로 넘겼다. 그러면
            // AR 탭이 컷 편집을 아예 무시해서, 잘라낸 앞뒤가 그대로 재생되고
            // "고른 구간에만 마스크를 씌우고 싶다"가 되지 않았다. 저장할 때
            // 굽는 구간([BanubaMaskExporter])과 같은 함수로 만든다.
            active.setVideoRanges(
                listOf(banubaVideoRange(sourceUri!!, totalMs, startMs, endMs)),
                0,
            )
            emitState(BanubaMaskContract.STATE_READY)
            null
        } catch (failure: Throwable) {
            Log.e(TAG, "prepare failed", failure)
            "영상을 미리보기에 올리지 못했어요."
        }
    }

    fun play() {
        val active = player
        active?.play(true)
        emitState(BanubaMaskContract.STATE_PLAYING)
    }

    fun pause() {
        player?.pause()
        emitState(BanubaMaskContract.STATE_PAUSED)
    }

    fun seekTo(positionMs: Int) {
        player?.seekTo(positionMs, true)
    }

    /// 얼굴 마스크를 건다. null이면 마스크만 걷어낸다.
    ///
    /// 효과 목록을 통째로 비우지 않는다 — 마스크 종류만 골라 교체한다. 나중에
    /// 색감이나 다른 효과가 같은 스택에 들어와도 서로를 지우지 않게 하기 위해서다.
    fun applyMask(effectName: String?, onDone: (String?) -> Unit) {
        val active = player ?: run {
            onDone("미리보기가 아직 준비되지 않았어요.")
            return
        }
        val generation = ++maskGeneration
        val previous = appliedMask

        if (effectName == null) {
            appliedMask = null
            active.setEffects(Effects())
            emitMask(null)
            onDone(null)
            return
        }

        emitState(BanubaMaskContract.STATE_PREPARING)
        // 효과 전개는 파일 복사라 첫 선택에서 수백 ms가 걸린다. 화면을 붙잡지
        // 않도록 딴 실을 쓰고, 돌아왔을 때 최신 선택인지 확인한다.
        Thread {
            val uri = effectHelper.prepareEffect(effectName)
            handler.post {
                if (generation != maskGeneration) return@post
                if (uri == null) {
                    appliedMask = previous
                    emitMask(previous)
                    onDone("'$effectName' 효과 파일을 찾지 못했어요.")
                    return@post
                }
                try {
                    val effects = Effects()
                    effects.visualStack.push(
                        VisualTimedEffect(
                            effectDrawable = VideoEffectsHelper.createMaskEffect(uri),
                        ),
                    )
                    active.setEffects(effects)
                    appliedMask = effectName
                    emitMask(effectName)
                    onDone(null)
                } catch (failure: Throwable) {
                    Log.e(TAG, "applyMask failed", failure)
                    appliedMask = previous
                    emitMask(previous)
                    onDone("마스크를 적용하지 못했어요.")
                }
            }
        }.start()
    }

    private fun emitState(state: String) = onEvent(
        mapOf(
            BanubaMaskContract.EVENT_TYPE to BanubaMaskContract.EVENT_STATE,
            "state" to state,
        ),
    )

    private fun emitMask(name: String?) = onEvent(
        mapOf(
            BanubaMaskContract.EVENT_TYPE to BanubaMaskContract.EVENT_MASK,
            "mask" to name,
        ),
    )

}

internal class BanubaMaskPreviewFactory(
    private val onCreated: (BanubaMaskPreview) -> Unit,
    private val onEvent: (Map<String, Any?>) -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        BanubaMaskPreview(context, onEvent).also(onCreated)
}
