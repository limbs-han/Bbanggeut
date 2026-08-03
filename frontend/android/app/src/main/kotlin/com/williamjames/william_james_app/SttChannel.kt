package com.williamjames.william_james_app

import android.content.Context
import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 자막용 오디오 추출 채널.
 *
 * MainActivity에 코드를 늘리지 않으려고 여기에 모았다 — 이 브랜치를 합칠 때
 * 저쪽 파일에는 [register] 호출 한 줄만 들어간다.
 *
 * 계약:
 *   method  decodeToWav
 *   args    { input: String, output: String }
 *   return  실제로 만든 WAV 경로
 *   error   "bad_args" | "decode_failed"
 *
 * 네이티브는 원본 샘플레이트의 모노 WAV만 만든다. 16kHz 변환은 Dart가 한다
 * (android_audio.dart) — MediaCodec 디코더에 출력 샘플레이트를 강제할 수 없다.
 */
object SttChannel {
    private const val CHANNEL = "stt/media"

    fun register(engine: FlutterEngine, context: Context) {
        val application = context.applicationContext
        // 내려받기 진행률을 네이티브에서 Dart로 밀어야 해서 채널을 들고 있는다.
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        val main = Handler(Looper.getMainLooper())
        channel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decodeToWav" -> {
                        val input = call.argument<String>("input")
                        val output = call.argument<String>("output")
                        if (input == null || output == null) {
                            result.error("bad_args", "input/output 경로가 필요합니다.", null)
                        } else {
                            decodeOffThread(input, output, result)
                        }
                    }
                    "mlkitReadiness" -> {
                        offThread(result) { MlKitTranscriber.readiness(application) }
                    }
                    // 마이크 권한은 Activity가 있어야 물을 수 있다. 화면이 없는
                    // 상태(백그라운드 전사 등)에서는 물어볼 방법이 없으니 그대로 알린다.
                    "mlkitRequestMic" -> {
                        val activity = context as? Activity
                        if (activity == null) {
                            result.success(false)
                        } else {
                            MicPermission.ensure(activity) { granted -> result.success(granted) }
                        }
                    }
                    "mlkitEnsure" -> {
                        offThread(result) {
                            MlKitTranscriber.ensure(application) { percent ->
                                main.post { channel.invokeMethod("mlkitDownloadProgress", percent) }
                            }
                        }
                    }
                    "mlkitTranscribe" -> {
                        val wav = call.argument<String>("wav")
                        if (wav == null) {
                            result.error("bad_args", "wav 경로가 필요합니다.", null)
                        } else {
                            offThread(result) {
                                MlKitTranscriber.transcribe(application, wav)
                                    .map { mapOf("startMs" to it.startMs, "endMs" to it.endMs, "text" to it.text) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * ML Kit 전사는 오디오를 실시간 속도로 흘려보내므로 **재생 시간만큼** 걸린다.
     * 절대 플랫폼 스레드에서 돌리면 안 된다.
     */
    private fun offThread(result: MethodChannel.Result, work: () -> Any?) {
        val main = Handler(Looper.getMainLooper())
        Thread {
            val outcome = runCatching(work)
            main.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        val code = if (it is MlKitTranscriber.Unavailable) "mlkit_unavailable" else "mlkit_failed"
                        result.error(code, it.message, null)
                    },
                )
            }
        }.start()
    }

    /**
     * 디코딩은 수 초가 걸릴 수 있어 플랫폼 스레드를 막으면 안 된다.
     * MethodChannel 응답은 반드시 메인 루퍼에서 돌려준다.
     */
    private fun decodeOffThread(
        input: String,
        output: String,
        result: MethodChannel.Result,
    ) {
        val main = Handler(Looper.getMainLooper())
        Thread {
            val decoded = runCatching { AudioDecoder.decodeToWav(input, output) }
            main.post {
                decoded.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("decode_failed", it.message, null) },
                )
            }
        }.start()
    }
}
