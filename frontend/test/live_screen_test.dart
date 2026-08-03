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

  testWidgets('실시간 맨 앞이면 빨간 불이 켜진다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(
          // 이미 맨 앞이면 당길 것이 없어 화면이 onTap을 주지 않는다.
          body: LiveEdgeChip(atLiveEdge: true, label: 'LIVE', onTap: null),
        ),
      ),
    );

    expect(_lampColor(tester), Colors.white);
    expect(_chipColor(tester), const Color(0xDDD32F2F));
    expect(
      tester
          .widget<InkWell>(
            find.descendant(
              of: find.byType(LiveEdgeChip),
              matching: find.byType(InkWell),
            ),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('실시간에서 뒤처지면 불이 꺼지고 누르면 맨 앞으로 당긴다', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: LiveEdgeChip(
            atLiveEdge: false,
            label: '실시간으로',
            onTap: () => taps += 1,
          ),
        ),
      ),
    );

    expect(_lampColor(tester), isNot(Colors.white));
    expect(_chipColor(tester), const Color(0xB32D312B));

    await tester.tap(find.byType(LiveEdgeChip));
    await tester.pump();
    expect(taps, 1);
  });
}

Color? _lampColor(WidgetTester tester) {
  final lamp = tester.widget<AnimatedContainer>(
    find.byKey(const Key('live-edge-lamp')),
  );
  return (lamp.decoration as BoxDecoration?)?.color;
}

Color? _chipColor(WidgetTester tester) => tester
    .widget<Material>(
      find.descendant(
        of: find.byType(LiveEdgeChip),
        matching: find.byType(Material),
      ),
    )
    .color;

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
