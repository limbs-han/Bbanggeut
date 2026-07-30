/// whisper 모델 파일을 확보한다.
///
/// **왜 복사하나**: whisper.cpp는 네이티브에서 파일 경로를 열기 때문에 Flutter
/// 에셋을 직접 읽을 수 없다. 에셋은 APK 안에 압축돼 있어 파일 경로가 없다.
/// 그래서 첫 실행 때 한 번 앱 폴더로 복사하고, 그다음부터는 있는 것을 쓴다.
///
/// 모델을 만드는 절차는 `자료/docs/사람이 읽을 문서/06-STT모델가이드.md`에 있다.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// APK에 담는 모델. 파일 이름에 양자화 종류가 들어 있어야 한다 — 모델을 바꿀 때
/// 이름이 같으면 기기에 남은 옛 사본을 계속 쓴다.
const whisperModelAsset = 'assets/models/ggml-small-ko-q5_1.bin';

/// 에셋을 무시하고 기기 안의 다른 모델을 쓰고 싶을 때. 다른 모델을 시험할 때만
/// 쓴다 — 비어 있으면 에셋을 쓴다.
const whisperModelOverride = String.fromEnvironment('WHISPER_MODEL_PATH');

/// 모델 파일의 절대 경로. 확보에 실패하면 던진다.
///
/// 순서: dart-define로 준 경로 → 에셋에서 복사한 사본.
///
/// 인자는 테스트용 이음매다. 실제 호출은 인자 없이 한다.
Future<String> resolveWhisperModel({
  String override = whisperModelOverride,
  Future<ByteData> Function(String key) loadAsset = _loadFromBundle,
  Future<Directory> Function() directory = getApplicationSupportDirectory,
}) async {
  if (override.isNotEmpty) {
    debugPrint('[stt] 모델: dart-define 경로를 씁니다 ($override)');
    return override;
  }

  final target = File(
    '${(await directory()).path}${Platform.pathSeparator}'
    '${whisperModelAsset.split('/').last}',
  );
  // 이름에 양자화 종류가 들어 있으므로, 있으면 같은 모델이다.
  if (target.existsSync() && await target.length() > 0) {
    return target.path;
  }

  // ponytail: 에셋 전체를 메모리에 올린다(167MB). Flutter에 에셋을 스트림으로
  // 읽는 API가 없다. 첫 실행에 한 번뿐이라 그대로 둔다 — 저사양 기기에서
  // 문제가 되면 네이티브에서 AssetManager로 스트리밍하는 경로가 필요하다.
  final ByteData data;
  try {
    data = await loadAsset(whisperModelAsset);
  } catch (error) {
    // 에셋을 안 넣고 빌드한 경우다. dart-define도 없으면 전사를 할 수 없다.
    throw StateError(
      'whisper 모델을 찾지 못했습니다. $whisperModelAsset을 에셋에 넣거나 '
      '--dart-define=WHISPER_MODEL_PATH=<기기 내 경로>로 지정하세요. '
      '만드는 절차는 자료/docs/사람이 읽을 문서/06-STT모델가이드.md 참조. ($error)',
    );
  }

  await target.parent.create(recursive: true);
  await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
  debugPrint('[stt] 모델을 에셋에서 복사했습니다 (${await target.length()}바이트)');
  return target.path;
}

Future<ByteData> _loadFromBundle(String key) => rootBundle.load(key);
