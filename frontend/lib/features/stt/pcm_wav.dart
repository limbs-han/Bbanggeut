/// 16비트 PCM WAV 파싱 — 순수 Dart. 합성 WAV로 전부 테스트된다.
///
/// ai_comic의 audio_analysis.dart에서 PcmWav만 떼냈다. 저쪽 파일의 나머지
/// (RMS 프로파일·소리 마커·컷 앵커)는 4컷 만화 전용이라 자막에 필요 없다.
library;

import 'dart:typed_data';

/// 16비트 PCM WAV. AudioExtractor가 `-acodec pcm_s16le`로 뽑은 것만 받는다.
class PcmWav {
  const PcmWav({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  /// 채널이 인터리브된 16비트 정수 샘플.
  final Int16List samples;
  final int sampleRate;
  final int channels;

  int get frameCount => channels == 0 ? 0 : samples.length ~/ channels;

  Duration get duration => sampleRate == 0
      ? Duration.zero
      : Duration(microseconds: (frameCount / sampleRate * 1000000).round());

  /// RIFF/WAVE 컨테이너에서 fmt·data 청크를 읽는다.
  static PcmWav parse(Uint8List bytes) {
    if (bytes.length < 44) throw const FormatException('WAV 헤더가 너무 짧습니다.');
    if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') {
      throw const FormatException('RIFF/WAVE 컨테이너가 아닙니다.');
    }
    final data = ByteData.sublistView(bytes);
    int? sampleRate;
    int? channels;
    int? bitsPerSample;
    var offset = 12;

    while (offset + 8 <= bytes.length) {
      final id = _tag(bytes, offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;

      if (id == 'fmt ' && body + 16 <= bytes.length) {
        final format = data.getUint16(body, Endian.little);
        if (format != 1) {
          throw FormatException('PCM이 아닌 WAV입니다 (format=$format).');
        }
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (sampleRate == null || channels == null || bitsPerSample == null) {
          throw const FormatException('data 청크가 fmt 청크보다 먼저 나왔습니다.');
        }
        if (bitsPerSample != 16) {
          throw FormatException('16비트 PCM이 아닙니다 ($bitsPerSample bit).');
        }
        if (channels == 0 || sampleRate == 0) {
          throw const FormatException('fmt 청크의 채널/샘플레이트가 0입니다.');
        }
        final end = body + size <= bytes.length ? body + size : bytes.length;
        final count = (end - body) ~/ 2;
        final samples = Int16List(count);
        for (var i = 0; i < count; i++) {
          samples[i] = data.getInt16(body + i * 2, Endian.little);
        }
        return PcmWav(
          samples: samples,
          sampleRate: sampleRate,
          channels: channels,
        );
      }
      // RIFF 청크는 2바이트 정렬이다.
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('data 청크를 찾지 못했습니다.');
  }

  static String _tag(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
}
