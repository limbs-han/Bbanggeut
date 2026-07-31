import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/local_edit_screen.dart';

void main() {
  testWidgets('영상 편집 준비 화면에 진행률과 기능 카드를 표시한다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _PendingDownloadApiClient();
    final controller = AppController(api: api);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: LocalEditScreen(
          controller: controller,
          video: const VideoMemory(
            id: 'video-1',
            deviceId: 'device-1',
            triggerType: 'LAUGHTER',
            title: '가족의 웃음',
            status: 'READY',
            favorite: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('editor-preparing-screen')), findsOneWidget);
    expect(find.text('추억 영상을\n불러오고 있어요'), findsOneWidget);
    expect(find.text('곧 편집을 시작할 수 있어요'), findsOneWidget);
    expect(find.byKey(const Key('editor-preparing-progress')), findsOneWidget);
    expect(find.text('준비 중 6%'), findsOneWidget);
    expect(find.text('자르기'), findsOneWidget);
    expect(find.text('음악'), findsOneWidget);
    expect(find.text('스티커'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _PendingDownloadApiClient extends ApiClient {
  final pendingUrl = Completer<SignedUrl>();

  @override
  Future<SignedUrl> createDownloadUrl(String id) => pendingUrl.future;
}
