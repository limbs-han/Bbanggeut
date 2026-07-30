/// 내보내기가 네이티브에 넘기는 자막 인자 모양을 고정한다.
/// Kotlin이 startMs/endMs/text 키를 그대로 읽으므로 이름이 바뀌면 조용히 자막이
/// 빠진 영상이 나온다.
///
/// **출력 경로는 반드시 임시 폴더를 쓴다.** exportEditedVideo가 출력 폴더를
/// 실제로 만들기 때문에(`outputFile.parent.createSync`), `/out/...` 같은 절대
/// 경로를 주면 리눅스에서 파일시스템 최상위에 폴더를 만들려다 권한 오류로
/// 죽는다. 윈도우에서는 C:\out이 되어 그냥 통과하므로 CI에서만 터진다.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/video_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.williamjames/video_canvas');
  final calls = <MethodCall>[];
  late Directory temporary;
  late String outputPath;

  setUp(() async {
    calls.clear();
    temporary = await Directory.systemTemp.createTemp('exporter-captions-');
    outputPath = '${temporary.path}${Platform.pathSeparator}edited.mp4';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'exportWithTrim' ? outputPath : null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  test('자동 자막을 주면 segments로 넘긴다', () async {
    await VideoEditorExporter().exportEditedVideo(
      inputPath: '/in/event.mp4',
      outputPath: outputPath,
      startMs: 0,
      endMs: 10000,
      aspectRatio: 16 / 9,
      captions: const [
        {'startMs': 1000, 'endMs': 3000, 'text': '그거 만지지 마'},
      ],
    );

    final args = calls.single.arguments as Map;
    final first = (args['segments'] as List).single as Map;
    expect(first['startMs'], 1000);
    expect(first['endMs'], 3000);
    expect(first['text'], '그거 만지지 마');
  });

  test('자동 자막이 없으면 빈 목록을 넘긴다 — 손 자막 경로가 종전대로 동작한다', () async {
    await VideoEditorExporter().exportEditedVideo(
      inputPath: '/in/event.mp4',
      outputPath: outputPath,
      startMs: 0,
      endMs: 0,
      aspectRatio: 16 / 9,
      captionText: '손으로 쓴 자막',
    );

    final args = calls.single.arguments as Map;
    expect(args['segments'], isEmpty);
    expect(args['captionText'], '손으로 쓴 자막');
  });
}
