package com.williamjames.william_james_app

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

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
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
                    else -> result.notImplemented()
                }
            }
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
