package com.williamjames.william_james_app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 영상 컨테이너에서 오디오 트랙을 16bit 모노 PCM WAV로 뽑는다.
 *
 * FFmpeg을 쓰지 않는 이유: MediaExtractor + MediaCodec은 Android에 기본 내장돼
 * 있어 추가 바이너리(30~50MB)도, GPL 변종 선택도 필요 없다.
 * ai_comic/lib/.../ffmpeg_audio.dart 의 근거 주석 참조.
 *
 * 여기서 하는 일은 "컨테이너를 열어 PCM을 뽑는다"까지다. 16kHz 리샘플은 Dart
 * (speech_analysis.dart의 resample)가 맡는다 — MediaCodec 디코더에 출력
 * 샘플레이트를 강제할 수 없고, 네이티브 코드를 최소로 두면 검증 가능한 로직이
 * Dart에 남는다.
 */
object AudioDecoder {

    private const val TIMEOUT_US = 10_000L

    /** 성공하면 [outputPath]를 돌려준다. 실패는 예외로 올린다. */
    fun decodeToWav(inputPath: String, outputPath: String): String {
        // MediaExtractor는 네이티브 자원과 파일 디스크립터를 잡는다. 트랙 탐색이나
        // 코덱 생성이 실패해도 반드시 풀어야 하므로 전체를 try/finally로 감싼다.
        val extractor = MediaExtractor()
        try {
            return decodeWith(extractor, inputPath, outputPath)
        } finally {
            extractor.release()
        }
    }

    private fun decodeWith(
        extractor: MediaExtractor,
        inputPath: String,
        outputPath: String,
    ): String {
        extractor.setDataSource(inputPath)

        var trackIndex = -1
        var trackFormat: MediaFormat? = null
        for (index in 0 until extractor.trackCount) {
            val candidate = extractor.getTrackFormat(index)
            val mime = candidate.getString(MediaFormat.KEY_MIME)
            if (mime != null && mime.startsWith("audio/")) {
                trackIndex = index
                trackFormat = candidate
                break
            }
        }
        val format = trackFormat
        if (trackIndex < 0 || format == null) {
            throw IllegalStateException("오디오 트랙이 없는 영상입니다.")
        }
        extractor.selectTrack(trackIndex)

        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val mime = format.getString(MediaFormat.KEY_MIME)!!

        // 부동소수 PCM을 내주는 기기가 있어 16bit를 명시적으로 요구한다.
        format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)

        val codec = MediaCodec.createDecoderByType(mime)
        val output = File(outputPath)
        output.parentFile?.mkdirs()
        val file = RandomAccessFile(output, "rw")

        try {
            codec.configure(format, null, null, 0)
            codec.start()

            file.setLength(0)
            file.write(ByteArray(44)) // 헤더 자리를 비워두고 마지막에 덮어쓴다.
            var pcmBytes = 0

            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                if (!inputDone) {
                    val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val buffer = codec.getInputBuffer(inputIndex)
                        val size =
                            if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inputIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(
                                inputIndex, 0, size, extractor.sampleTime, 0,
                            )
                            extractor.advance()
                        }
                    }
                }

                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                when {
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // 디코더가 실제 채널 수를 알려준다 — 다운믹스에 필요하다.
                        // getInteger(name, default)와 containsKey는 API 29부터라
                        // minSdk 24에서 쓸 수 없다. 키가 없으면 NPE가 나므로 감싼다.
                        channelCount = runCatching {
                            codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }.getOrDefault(channelCount)
                    }
                    outputIndex >= 0 -> {
                        val buffer = codec.getOutputBuffer(outputIndex)
                        if (buffer != null && bufferInfo.size > 0) {
                            pcmBytes += writeMono(file, buffer, bufferInfo, channelCount)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                }
            }

            if (pcmBytes == 0) throw IllegalStateException("디코드된 오디오가 비어 있습니다.")
            file.seek(0)
            file.write(wavHeader(pcmBytes, sampleRate))
            return outputPath
        } finally {
            file.close()
            runCatching { codec.stop() }
            codec.release()
        }
    }

    /** 채널을 평균해 모노로 접어 리틀엔디언 16bit로 쓴다. 쓴 바이트 수를 돌려준다. */
    private fun writeMono(
        file: RandomAccessFile,
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        channelCount: Int,
    ): Int {
        // limit을 먼저 올린 뒤 position을 옮긴다 — 순서를 바꾸면 이전 limit이
        // offset보다 작을 때 IllegalArgumentException이 난다.
        buffer.clear()
        buffer.limit(info.offset + info.size)
        buffer.position(info.offset)
        val shorts = buffer.order(ByteOrder.nativeOrder()).asShortBuffer()
        val channels = if (channelCount > 0) channelCount else 1
        val frames = shorts.remaining() / channels
        if (frames <= 0) return 0

        val mono = ByteBuffer.allocate(frames * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until frames) {
            var sum = 0
            for (channel in 0 until channels) {
                sum += shorts.get(frame * channels + channel).toInt()
            }
            mono.putShort((sum / channels).toShort())
        }
        file.write(mono.array())
        return frames * 2
    }

    /** 44바이트 RIFF/WAVE 헤더 (모노 16bit). */
    private fun wavHeader(dataSize: Int, sampleRate: Int): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(36 + dataSize)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)
        header.putShort(1) // PCM
        header.putShort(1) // mono
        header.putInt(sampleRate)
        header.putInt(sampleRate * 2) // byte rate = rate * channels * bytesPerSample
        header.putShort(2) // block align
        header.putShort(16) // bits per sample
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(dataSize)
        return header.array()
    }
}
