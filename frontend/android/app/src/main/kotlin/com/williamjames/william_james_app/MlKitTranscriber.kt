package com.williamjames.william_james_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.ParcelFileDescriptor
import androidx.core.content.ContextCompat
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * ML Kit GenAI 온디바이스 음성 인식으로 자막을 만든다 — whisper의 대안 경로.
 *
 * **실험 중이다.** 측정 근거와 절차는 `ai/stt_benchmark/mlkit_spike.py` 참조.
 *
 * 반드시 알아야 하는 제약 넷:
 *
 *  1. **입력은 raw PCM(16kHz·모노·16-bit LE)뿐이다.** 컨테이너를 받지 않는다.
 *     앱이 이미 [AndroidAudioExtractor]로 같은 형식의 WAV를 만들므로 헤더만 벗긴다.
 *  2. **한꺼번에 주면 안 된다.** 엔진 내부 버퍼가 넘쳐 ERROR_TYPE_AUDIO_BUFFER_OVERFLOW다.
 *     파이프로 나눠 먹인다([PACE] 주석 참조).
 *  3. **파일 입력인데도 RECORD_AUDIO 런타임 권한을 요구한다.**
 *  4. **기기마다 쓸 수 있는지 다르다.** advanced 모드는 Pixel 10 전용이라 쓰지 않는다.
 *
 * ## 타임스탬프를 어떻게 얻나
 *
 * 엔진은 시각을 주지 않는다. 그런데 관찰해 보니 **partial 응답이 누적 텍스트**이고
 * 글자가 늘어날 때마다 도착한다 — 75초 클립에서 final은 4개뿐인데 partial은 94개였다.
 * 그래서 "이 낱말이 처음 등장한 시점에 먹인 오디오 길이"를 낱말의 시각으로 삼는다.
 *
 * 실제 정답지와 대조했을 때 오차가 ±2초 안이었다(15초→16.6초, 28초→28.8초,
 * 54초→55.4초). final만 쓰면 한 덩이가 28~63초를 통째로 덮어 불가능한 정밀도다.
 *
 * **내용은 final에서, 시각만 partial에서 가져온다.** partial은 텍스트를 고치기도
 * 해서(`물러나`→`물러`→`물러시오`) 내용으로 쓰면 오염된다.
 *
 * 엔진이 듣고 난 뒤 내놓으므로 시각이 일정하게 조금 늦다. 보정 상수는 아직 넣지
 * 않았다 — 클립 하나에서 얻은 값이라 근거가 얇다.
 */
object MlKitTranscriber {

    data class Line(val startMs: Long, val endMs: Long, val text: String)

    class Unavailable(message: String) : Exception(message)

    /** 16kHz·모노·16-bit → 1ms당 32바이트. 바이트 수를 시각으로 바꿀 때 쓴다. */
    private const val BYTES_PER_MS = 32
    private const val CHUNK_MS = 100L
    private const val CHUNK_BYTES = BYTES_PER_MS * CHUNK_MS.toInt()

    /**
     * 급여 배속. 빨리 **먹이는** 것이지 오디오를 빨리 **재생**하는 게 아니다 —
     * 샘플은 그대로라 음정도 인식 결과도 바뀌지 않는다. 실제로 1·4·8배속의
     * 전사문이 한 글자도 다르지 않았고, 타임스탬프 앵커도 4배속과 8배속이
     * 같은 자리에 찍혔다(16.6s / 28.9s / 55.6s).
     *
     * 쉬지 않고 밀면 ERROR_TYPE_AUDIO_BUFFER_OVERFLOW로 죽는다. 파이프 역압이
     * "먹인 위치 ≈ 엔진이 처리 중인 위치"를 지켜 주는데, 더 올리면 그 결합이
     * 끊어질 수 있다 — 올리려면 앵커 정렬을 다시 재고 올려라.
     */
    private const val PACE = 8

    /**
     * 낱말 사이가 이만큼 벌어지면 자막을 끊는다. **쉼을 자막 밖으로 빼내는 값이다.**
     *
     * 시행착오를 남긴다. 처음 1.5초로 뒀더니 표시 속도가 0.8~8.3자/초로 널뛰었다.
     * 쉼이 자막 **안에** 갇혀서 12자가 15.8초를 버티는 줄이 생겼기 때문이다.
     * 그걸 "표시 시간을 글자 수로 정하자"로 풀려 했는데 두 번 다 틀렸다 —
     * 상한을 걸었더니 Dart가 재분할하며 조각당 0.7초가 됐고, 상한을 풀었더니
     * 실제 발화보다 길어져 뒤로 밀렸다.
     *
     * 옳은 방법은 속도를 강제하는 게 아니라 **쉼을 빼는 것**이다. 문턱을 낮추면
     * 쉼이 자막 사이 공백으로 나가고, 남은 자막은 말이 이어지는 구간뿐이라
     * 속도가 저절로 고르다. 시각은 앵커 그대로 두므로 밀리지도 않는다.
     */
    private const val GAP_MS = 800L

    /** 마지막 낱말이 곧바로 사라지지 않도록 붙이는 꼬리. 다음 줄을 침범하지 않는다. */
    private const val TAIL_MS = 400L

    /**
     * 이보다 느리게 지나가는 자막은 끝을 당긴다 — 11자가 17.7초를 버티는 줄이 있었다.
     * 시작은 안 건드리므로 위치는 그대로고 화면에 머무는 시간만 줄어든다.
     */
    private const val MIN_CHARS_PER_SECOND = 2.0

    /**
     * 자막 한 줄의 최대 글자 수. Dart의 `captionMaxChars`와 같은 값이다.
     *
     * **여기서 끊는 것이 중요하다.** 긴 줄로 넘기면 Dart의 `splitIntoLines`가
     * 시간을 글자 수 비율로 나눠 쪼개는데, 그 안에 쉼이 있으면 조각이 실제
     * 발화와 무관한 자리에 박힌다 — 50초에 나온 말이 30초 자막으로 뜬 원인이다.
     * 낱말마다 진짜 시각을 알고 있으니 비례 배분에 맡기지 않고 직접 끊는다.
     */
    private const val MAX_CHARS = 20

    /**
     * 이 기기에서 지금 쓸 수 있는 상태인지. Dart가 이 값으로 안내를 고른다.
     *
     * `checkStatus()`가 네 값을 주는데 그중 **DOWNLOADABLE을 실패로 보면 안 된다** —
     * 모델만 받으면 되는 기기를 포기하게 된다. whisper 폴백이 있을 때는 티가 안
     * 났지만, 폴백을 걷어내면 그대로 "자막 없음"이 된다.
     */
    const val READY = "ready"
    const val NEEDS_DOWNLOAD = "needs_download"
    const val NEEDS_PERMISSION = "needs_permission"
    const val UNAVAILABLE = "unavailable"

    fun readiness(context: Context): String = runBlocking {
        if (!hasMicPermission(context)) return@runBlocking NEEDS_PERMISSION
        runCatching {
            SpeechRecognition.getClient(basicOptions()).use {
                when (it.checkStatus()) {
                    FeatureStatus.AVAILABLE -> READY
                    FeatureStatus.DOWNLOADABLE, FeatureStatus.DOWNLOADING -> NEEDS_DOWNLOAD
                    else -> UNAVAILABLE
                }
            }
        }.getOrDefault(UNAVAILABLE)
    }

    /**
     * 필요하면 모델을 내려받고 최종 상태를 돌려준다. 네트워크가 필요하고 몇 분
     * 걸릴 수 있어 [onProgress]로 진행률(0~100)을 흘려보낸다.
     */
    fun ensure(context: Context, onProgress: (Int) -> Unit): String = runBlocking {
        if (!hasMicPermission(context)) return@runBlocking NEEDS_PERMISSION
        runCatching {
            SpeechRecognition.getClient(basicOptions()).use { recognizer ->
                if (recognizer.checkStatus() == FeatureStatus.AVAILABLE) return@use READY

                // 전체 크기는 DownloadStarted가 한 번만 알려준다. DownloadProgress에는
                // 받은 양만 들어 있어서, 이걸 안 잡아 두면 퍼센트를 못 낸다.
                var total = 0L
                recognizer.download().collect { progress ->
                    when (progress) {
                        is DownloadStatus.DownloadStarted -> total = progress.bytesToDownload
                        is DownloadStatus.DownloadProgress -> if (total > 0) {
                            onProgress((progress.totalBytesDownloaded * 100 / total).toInt().coerceIn(0, 100))
                        }
                        is DownloadStatus.DownloadFailed -> throw progress.e
                        else -> Unit
                    }
                }
                if (recognizer.checkStatus() == FeatureStatus.AVAILABLE) READY else UNAVAILABLE
            }
        }.getOrDefault(UNAVAILABLE)
    }

    /**
     * [wavPath]는 16kHz 모노 PCM WAV여야 한다([AndroidAudioExtractor]의 출력).
     * 인식된 구간들을 순서대로 돌려준다. 무발화면 빈 목록이다.
     */
    fun transcribe(context: Context, wavPath: String): List<Line> = runBlocking {
        if (!hasMicPermission(context)) {
            // 파일을 주는데도 필요하다. 없으면 ERROR_TYPE_INSUFFICIENT_PERMISSION으로 죽는다.
            throw Unavailable("RECORD_AUDIO 권한이 없습니다.")
        }

        val bytes = File(wavPath).readBytes()
        val start = pcmDataOffset(bytes)

        SpeechRecognition.getClient(basicOptions()).use { recognizer ->
            if (recognizer.checkStatus() != FeatureStatus.AVAILABLE) {
                throw Unavailable("이 기기에서 ML Kit 음성 인식을 쓸 수 없습니다.")
            }

            val fed = AtomicLong(0)
            val pipe = ParcelFileDescriptor.createPipe()
            val writer = Thread {
                runCatching {
                    ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { out ->
                        var offset = start
                        while (offset < bytes.size) {
                            val n = minOf(CHUNK_BYTES, bytes.size - offset)
                            out.write(bytes, offset, n)
                            out.flush()
                            offset += n
                            fed.addAndGet(n.toLong())
                            Thread.sleep(CHUNK_MS / PACE)
                        }
                    }
                }
            }
            writer.start()

            val lines = mutableListOf<Line>()
            // 한 final이 끝날 때까지 쌓이는 (먹인 위치, 누적 텍스트) 기록.
            val partials = mutableListOf<Pair<Long, String>>()
            try {
                pipe[0].use { pfd ->
                    val request = speechRecognizerRequest { audioSource = AudioSource.fromPfd(pfd) }
                    recognizer.startRecognition(request).collect { response ->
                        when (response) {
                            is SpeechRecognizerResponse.PartialTextResponse ->
                                partials += (fed.get() / BYTES_PER_MS) to response.text
                            is SpeechRecognizerResponse.FinalTextResponse -> {
                                lines += toLines(response.text, partials, fed.get() / BYTES_PER_MS)
                                partials.clear()
                            }
                            else -> Unit
                        }
                    }
                }
            } catch (error: Exception) {
                // 무발화는 예외로 온다. 빈 자막은 실패가 아니다 — 그대로 돌려준다.
                if (lines.isEmpty() && error.message?.contains("NO_SPEECH") != true) throw error
            } finally {
                writer.join(2_000)
            }
            lines.sortedBy { it.startMs }
        }
    }

    /**
     * final 텍스트에 시각을 붙여 자막 줄로 나눈다.
     *
     * 각 글자가 partial에서 **처음** 등장한 시점을 그 글자의 시각으로 삼는다.
     * partial이 텍스트를 되돌리는 경우가 있어 "처음"이 중요하다 — 나중 값을 쓰면
     * 수정이 일어난 낱말만 뒤로 밀린다.
     */
    private fun toLines(
        finalText: String,
        partials: List<Pair<Long, String>>,
        fallbackMs: Long,
    ): List<Line> {
        val text = finalText.trim()
        if (text.isEmpty()) return emptyList()

        // charTime[i] = i번째 글자까지 인식된 시점. 앞에서부터 단조 증가로 채운다.
        val charTime = LongArray(text.length + 1) { -1 }
        var reached = 0
        for ((ms, partial) in partials) {
            val common = commonPrefixLength(text, partial.trim())
            while (reached < common) {
                reached++
                charTime[reached] = ms
            }
        }
        // partial이 final을 끝까지 못 따라간 부분은 마지막으로 알려진 시각으로 둔다.
        var last = if (charTime[0] >= 0) charTime[0] else partials.firstOrNull()?.first ?: fallbackMs
        for (i in charTime.indices) {
            if (charTime[i] < 0) charTime[i] = last else last = charTime[i]
        }

        // 낱말 단위로 시각을 모으고, 사이가 벌어지면 줄을 끊는다.
        val out = mutableListOf<Line>()
        val buffer = StringBuilder()
        var lineStart = charTime[0]
        var lineEnd = charTime[0]
        var previousWordEnd = charTime[0]
        var index = 0

        while (index < text.length) {
            if (text[index] == ' ') {
                buffer.append(' ')
                index++
                continue
            }
            val wordStart = index
            while (index < text.length && text[index] != ' ') index++
            val startedAt = charTime[wordStart]
            val endedAt = charTime[index]

            val wouldOverflow =
                buffer.count { !it.isWhitespace() } + (index - wordStart) > MAX_CHARS
            if (buffer.isNotBlank() && (startedAt - previousWordEnd >= GAP_MS || wouldOverflow)) {
                out += Line(lineStart, maxOf(lineEnd, lineStart + 1), buffer.toString().trim())
                buffer.setLength(0)
                lineStart = startedAt
            }
            if (buffer.isBlank()) lineStart = startedAt
            buffer.append(text, wordStart, index)
            lineEnd = endedAt
            previousWordEnd = endedAt
        }
        if (buffer.isNotBlank()) {
            out += Line(lineStart, maxOf(lineEnd, lineStart + 1), buffer.toString().trim())
        }

        // 시작은 앵커 그대로 두고, 길이만 글자 수로 다시 정한다. 다음 줄은 침범하지 않는다.
        return finish(out)
    }

    /**
     * 끝 시각만 손본다. **시작은 절대 옮기지 않는다** — 옮겼다가 실제 발화보다
     * 뒤로 밀린 전력이 있다.
     *
     * 두 가지를 고친다.
     *
     *  1. 길이가 0인 줄. 한 partial에 텍스트가 몰려 들어오면 여러 줄이 같은 앵커를
     *     갖고, 그러면 끝 = 다음 줄 시작 = 자기 시작이 되어 화면에 아예 안 뜬다.
     *     같은 앵커를 공유하는 묶음은 다음 **다른** 앵커까지를 글자 수로 나눠 갖는다.
     *     여기서만 비례 배분을 쓰는데, 구간이 짧아 어긋나야 얼마 안 어긋난다.
     *  2. 너무 오래 머무는 줄. 17.7초 동안 11자가 떠 있던 경우가 있었다.
     *     끝을 당기기만 하므로 위치는 그대로다.
     */
    private fun finish(lines: List<Line>): List<Line> {
        if (lines.isEmpty()) return lines
        val out = ArrayList<Line>(lines.size)
        var i = 0
        while (i < lines.size) {
            // 시작 시각이 같은 묶음을 모은다.
            var j = i
            while (j + 1 < lines.size && lines[j + 1].startMs == lines[i].startMs) j++
            val nextStart = if (j + 1 < lines.size) lines[j + 1].startMs else Long.MAX_VALUE

            if (j > i) {
                val span = minOf(nextStart, lines[j].endMs + TAIL_MS) - lines[i].startMs
                val total = (i..j).sumOf { lines[it].text.count { c -> !c.isWhitespace() } }.coerceAtLeast(1)
                var at = lines[i].startMs
                for (k in i..j) {
                    val chars = lines[k].text.count { !it.isWhitespace() }
                    val end = if (k == j) lines[i].startMs + span else at + span * chars / total
                    out += lines[k].copy(startMs = at, endMs = maxOf(at + 1, end))
                    at = maxOf(at + 1, end)
                }
            } else {
                val chars = lines[i].text.count { !it.isWhitespace() }
                val longest = (chars / MIN_CHARS_PER_SECOND * 1000).toLong()
                val end = minOf(lines[i].endMs + TAIL_MS, lines[i].startMs + longest, nextStart)
                out += lines[i].copy(endMs = maxOf(lines[i].startMs + 1, end))
            }
            i = j + 1
        }
        return out
    }

    private fun commonPrefixLength(a: String, b: String): Int {
        var i = 0
        while (i < a.length && i < b.length && a[i] == b[i]) i++
        return i
    }

    private fun basicOptions(): SpeechRecognizerOptions = speechRecognizerOptions {
        locale = Locale.KOREA
        // advanced는 Pixel 10 전용이라 쓰지 않는다 — 요청하면 이 기기에서 실패한다.
        preferredMode = SpeechRecognizerOptions.Mode.MODE_BASIC
    }

    private fun hasMicPermission(context: Context) =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * WAV의 `data` 청크 시작 위치를 찾는다.
     *
     * 44바이트로 단정하지 않는 이유: 인코더가 `LIST`/`fact` 같은 청크를 끼워 넣으면
     * 헤더가 길어진다. 그걸 PCM으로 착각해 먹이면 앞부분이 잡음이 된다.
     */
    private fun pcmDataOffset(bytes: ByteArray): Int {
        var i = 12 // "RIFF" + size + "WAVE"
        while (i + 8 <= bytes.size) {
            val id = String(bytes, i, 4, Charsets.US_ASCII)
            val size = (bytes[i + 4].toInt() and 0xFF) or
                ((bytes[i + 5].toInt() and 0xFF) shl 8) or
                ((bytes[i + 6].toInt() and 0xFF) shl 16) or
                ((bytes[i + 7].toInt() and 0xFF) shl 24)
            if (id == "data") return i + 8
            i += 8 + size + (size and 1) // 청크는 짝수 경계로 정렬된다
        }
        return minOf(44, bytes.size) // data를 못 찾으면 표준 헤더 길이로 물러선다
    }
}
