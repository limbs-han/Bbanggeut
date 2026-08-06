/// ML Kit GenAI 온디바이스 음성 인식 — 자막 생성 경로.
///
/// 두 가지를 미리 알아야 한다.
///
///  - **전사는 재생 시간의 약 1/8**이 걸린다. 오디오를 8배속으로 흘려보낸다.
///    빨리 먹이는 것이지 재생을 빠르게 하는 게 아니라 인식 결과는 같다.
///  - **기기마다 쓸 수 있는지 다르다.** [MlKitTranscriber.readiness]로 먼저 확인한다.
///
/// 측정 근거와 절차는 `ai/stt_benchmark/mlkit_spike.py` 참조.
library;

import 'package:flutter/services.dart';

import 'android_audio.dart' show sttMediaChannel;
import 'caption_line.dart';

/// 자막을 만들 수 있는 상태인지. Kotlin `MlKitTranscriber`의 상수와 값이 같아야 한다.
enum MlKitReadiness {
  /// 바로 쓸 수 있다.
  ready,

  /// 모델만 내려받으면 된다. [MlKitTranscriber.ensure]를 부른다.
  needsDownload,

  /// 마이크 권한이 없다. **파일 입력인데도 필요하다.**
  needsPermission,

  /// 이 기기에서는 못 쓴다.
  unavailable;

  static MlKitReadiness parse(String? raw) => switch (raw) {
    'ready' => MlKitReadiness.ready,
    'needs_download' => MlKitReadiness.needsDownload,
    'needs_permission' => MlKitReadiness.needsPermission,
    _ => MlKitReadiness.unavailable,
  };
}

class MlKitTranscriber {
  MlKitTranscriber({MethodChannel? channel})
    : channel = channel ?? const MethodChannel(sttMediaChannel);

  final MethodChannel channel;

  /// 지금 상태. 네이티브가 없거나 오류면 [MlKitReadiness.unavailable]로 삼킨다.
  Future<MlKitReadiness> readiness() async {
    try {
      return MlKitReadiness.parse(
        await channel.invokeMethod<String>('mlkitReadiness'),
      );
    } on PlatformException {
      return MlKitReadiness.unavailable;
    } on MissingPluginException {
      return MlKitReadiness.unavailable;
    }
  }

  /// 마이크 권한을 묻는다. 이미 있으면 즉시 true.
  ///
  /// 사용자가 "다시 묻지 않음"을 골랐다면 대화상자 없이 false가 온다 —
  /// 호출부가 설정으로 안내해야 한다.
  Future<bool> requestMicrophone() async {
    try {
      return await channel.invokeMethod<bool>('mlkitRequestMic') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 필요하면 모델을 내려받고 최종 상태를 돌려준다.
  ///
  /// 네트워크가 필요하고 몇 분 걸릴 수 있다. [onProgress]로 0~100이 올라온다 —
  /// 진행 표시가 없으면 멈춘 것처럼 보인다.
  Future<MlKitReadiness> ensure({
    void Function(int percent)? onProgress,
  }) async {
    if (onProgress != null) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'mlkitDownloadProgress') {
          onProgress((call.arguments as num).toInt());
        }
      });
    }
    try {
      return MlKitReadiness.parse(
        await channel.invokeMethod<String>('mlkitEnsure'),
      );
    } on PlatformException {
      return MlKitReadiness.unavailable;
    } on MissingPluginException {
      return MlKitReadiness.unavailable;
    } finally {
      // 핸들러를 걸어 둔 채 두면 다음 호출의 진행률이 옛 콜백으로 샌다.
      if (onProgress != null) channel.setMethodCallHandler(null);
    }
  }

  /// [wavPath]는 16kHz 모노 PCM WAV여야 한다(`AndroidAudioExtractor`의 출력).
  ///
  /// 시각은 **근사치다.** 엔진이 타임스탬프를 주지 않아 각 낱말이 처음 인식된
  /// 시점으로 역산한다. 실제 정답과 대조했을 때 오차가 ±2초 안이었다.
  /// [onProgress]로 **실제** 진행률(0~99)이 올라온다. 네이티브가 오디오를 직접
  /// 먹이므로 "얼마나 먹였는가"를 알고, 그것이 남은 일의 양이다.
  Future<List<CaptionLine>> transcribe(
    String wavPath, {
    void Function(int percent)? onProgress,
  }) async {
    if (onProgress != null) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'mlkitTranscribeProgress') {
          onProgress((call.arguments as num).toInt());
        }
      });
    }
    final List<Map<Object?, Object?>>? raw;
    try {
      raw = await channel.invokeListMethod<Map<Object?, Object?>>(
        'mlkitTranscribe',
        {'wav': wavPath},
      );
    } finally {
      // 걸어 둔 채 두면 다음 호출의 진행률이 옛 콜백으로 샌다(ensure와 같다).
      if (onProgress != null) channel.setMethodCallHandler(null);
    }
    if (raw == null) return const [];
    return raw
        .map(
          (line) => CaptionLine(
            startMs: (line['startMs'] as num).toInt(),
            endMs: (line['endMs'] as num).toInt(),
            text: (line['text'] as String?) ?? '',
          ),
        )
        .where((line) => line.text.isNotEmpty)
        .toList();
  }
}
