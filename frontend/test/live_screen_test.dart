import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/live_screen.dart';

void main() {
  testWidgets('비활성 홈 탭에서는 라이브 세션을 시작하지 않는다', (tester) async {
    final api = _LiveApiClient();
    final controller = AppController(api: api);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: EmbeddedLivePlayer(
            controller: controller,
            device: _LiveApiClient.device,
            status: const DeviceStatus(
              status: 'ONLINE',
              recording: true,
              uploadQueueDepth: 0,
            ),
            isActive: false,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('live-play-button')));
    await tester.pump();

    expect(api.createStreamCalls, 0);
    controller.dispose();
  });
}

class _LiveApiClient extends ApiClient {
  static const device = DeviceSummary(
    id: 'device-1',
    name: '거실 카메라',
    model: 'test',
    status: 'ONLINE',
    myRole: 'OWNER',
    retentionDays: 30,
  );

  int createStreamCalls = 0;

  @override
  Future<StreamSession> createStream(String deviceId) async {
    createStreamCalls += 1;
    return const StreamSession(
      id: 'stream-1',
      status: 'PENDING',
      heartbeatIntervalSeconds: 15,
    );
  }
}
