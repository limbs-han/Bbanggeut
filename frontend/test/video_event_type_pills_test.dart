import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/widgets.dart';

void main() {
  testWidgets('복합 이벤트 영상을 웃음과 박수 배지로 표시한다', (tester) async {
    const video = VideoMemory(
      id: 'mixed-video-id',
      deviceId: 'device-id',
      triggerType: 'LAUGHTER',
      eventTypes: ['LAUGHTER', 'CLAP'],
      title: '웃음과 박수가 함께 포착됐어요',
      status: 'READY',
      favorite: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VideoEventTypePills(video: video)),
      ),
    );

    expect(find.text('웃음'), findsOneWidget);
    expect(find.text('박수'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
