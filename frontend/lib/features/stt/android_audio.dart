/// 영상에서 16kHz 모노 WAV를 뽑는다 — MediaExtractor/MediaCodec 기반.
///
/// **왜 FFmpeg이 아닌가**: 안드로이드가 이미 코덱을 갖고 있다. FFmpeg 바이너리를
/// 넣으면 APK가 수십 MB 커지고 GPL 부담이 붙는다.
///
/// 네이티브는 **원본 샘플레이트의 모노 WAV**만 만든다. MediaCodec 디코더에
/// 출력 샘플레이트를 강제할 수 없기 때문이며, 16kHz 변환은 Dart의 [resample]이
/// 담당한다.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'pcm_wav.dart';
import 'speech_analysis.dart';

/// 네이티브 채널 이름 — Kotlin 쪽과 이 값이 일치해야 한다.
const sttMediaChannel = 'stt/media';

/// whisper가 받는 샘플레이트. 이 값을 바꾸면 모델이 못 알아듣는다.
const sttSampleRate = 16000;

class AndroidAudioExtractor {
  AndroidAudioExtractor({MethodChannel? channel})
    : channel = channel ?? const MethodChannel(sttMediaChannel);

  final MethodChannel channel;

  /// [videoPath]의 오디오를 16kHz 모노 WAV로 만들어 그 경로를 돌려준다.
  ///
  /// 네이티브가 없으면(플러그인 미등록) MissingPluginException이 올라간다.
  /// 호출부가 흡수해 자막 없이 진행한다.
  Future<String> toPcmWav16k(String videoPath, String outputPath) async {
    final intermediatePath = '$outputPath.native.wav';
    final produced = await channel.invokeMethod<String>('decodeToWav', {
      'input': videoPath,
      'output': intermediatePath,
    });
    if (produced == null) {
      throw StateError('네이티브 오디오 디코더가 결과 경로를 돌려주지 않았습니다.');
    }

    final intermediate = File(produced);
    try {
      final decoded = PcmWav.parse(await intermediate.readAsBytes());
      final converted = resample(decoded, sttSampleRate);
      if (converted.frameCount == 0) {
        throw StateError('오디오 트랙이 비어 있습니다.');
      }
      await File(outputPath).writeAsBytes(encodeWav(converted));
      return outputPath;
    } finally {
      if (intermediate.existsSync()) await intermediate.delete();
    }
  }
}
