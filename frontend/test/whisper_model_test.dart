/// 모델 확보 경로 테스트.
///
/// 이 로직이 틀리면 앱이 매번 167MB를 다시 복사하거나(느림), 모델이 없는데도
/// 조용히 진행해 원인을 짚기 어려운 실패가 된다.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/whisper_model.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('whisper-model-');
  });

  tearDown(() async {
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  ByteData fakeAsset(int bytes) =>
      ByteData.sublistView(Uint8List.fromList(List.filled(bytes, 7)));

  File copied() => File(
    '${temporary.path}${Platform.pathSeparator}ggml-small-ko-q5_1.bin',
  );

  test('dart-define 경로가 있으면 에셋을 건드리지 않는다', () async {
    var loaded = 0;
    final path = await resolveWhisperModel(
      override: '/data/data/pkg/files/other-model.bin',
      loadAsset: (_) async {
        loaded++;
        return fakeAsset(4);
      },
      directory: () async => temporary,
    );

    expect(path, '/data/data/pkg/files/other-model.bin');
    expect(loaded, 0);
  });

  test('에셋을 파일로 복사하고 그 경로를 돌려준다', () async {
    final path = await resolveWhisperModel(
      override: '',
      loadAsset: (key) async {
        expect(key, whisperModelAsset);
        return fakeAsset(16);
      },
      directory: () async => temporary,
    );

    expect(path, copied().path);
    expect(await copied().length(), 16);
  });

  test('이미 복사돼 있으면 다시 복사하지 않는다', () async {
    await copied().writeAsBytes(List.filled(16, 7));
    var loaded = 0;

    final path = await resolveWhisperModel(
      override: '',
      loadAsset: (_) async {
        loaded++;
        return fakeAsset(16);
      },
      directory: () async => temporary,
    );

    expect(path, copied().path);
    expect(loaded, 0, reason: '167MB를 매번 다시 쓰면 첫 화면이 느려진다');
  });

  test('빈 파일이 남아 있으면 다시 복사한다', () async {
    await copied().writeAsBytes(const <int>[]);

    await resolveWhisperModel(
      override: '',
      loadAsset: (_) async => fakeAsset(16),
      directory: () async => temporary,
    );

    expect(await copied().length(), 16);
  });

  test('에셋도 dart-define도 없으면 안내와 함께 던진다', () async {
    await expectLater(
      resolveWhisperModel(
        override: '',
        loadAsset: (_) async => throw Exception('asset not found'),
        directory: () async => temporary,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          '안내 문구',
          allOf(contains('06-STT모델가이드.md'), contains('WHISPER_MODEL_PATH')),
        ),
      ),
    );
  });
}
