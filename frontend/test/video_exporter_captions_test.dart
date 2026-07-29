/// 내보내기가 네이티브에 넘기는 자막 인자 모양을 고정한다.
/// Kotlin이 startMs/endMs/text 키를 그대로 읽으므로 이름이 바뀌면 조용히 자막이
/// 빠진 영상이 나온다.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/video_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.williamjames/video_canvas');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'exportWithTrim' ? '/out/edited.mp4' : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('자동 자막을 주면 segments로 넘긴다', () async {
    await VideoEditorExporter().exportEditedVideo(
      inputPath: '/in/event.mp4',
      outputPath: '/out/edited.mp4',
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
      outputPath: '/out/edited.mp4',
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
