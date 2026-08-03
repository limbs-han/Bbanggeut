import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/local_edit_screen.dart';

void main() {
  for (final size in const [Size(320, 568), Size(360, 640), Size(390, 844)]) {
    testWidgets(
      '${size.width.toInt()}×${size.height.toInt()} 준비 화면이 스크롤 없이 한 화면에 들어온다',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final api = _PendingDownloadApiClient();
        final controller = AppController(api: api);
        addTearDown(controller.dispose);
        final cacheDirectory = Directory.systemTemp.createTempSync(
          'editor-loading-test-',
        );
        addTearDown(() {
          if (cacheDirectory.existsSync()) {
            cacheDirectory.deleteSync(recursive: true);
          }
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: LocalEditScreen(
              controller: controller,
              cacheDirectoryProvider: () async => cacheDirectory,
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

        expect(
          find.byKey(const Key('editor-preparing-screen')),
          findsOneWidget,
        );
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(find.text('추억 영상을\n불러오고 있어요'), findsOneWidget);
        expect(find.text('곧 편집을 시작할 수 있어요'), findsOneWidget);
        expect(
          find.byKey(const Key('editor-preparing-progress')),
          findsOneWidget,
        );
        expect(find.text('준비 중 6%'), findsOneWidget);
        final illustration = find.byKey(
          const Key('editor-preparing-feature-illustration'),
        );
        expect(illustration, findsOneWidget);
        final image = tester.widget<Image>(
          find.descendant(of: illustration, matching: find.byType(Image)),
        );
        // 그릴 크기로만 풀도록 cacheWidth를 주면 Image.asset이 AssetImage를
        // ResizeImage로 한 겹 싼다. 어느 쪽이든 원본 에셋은 같아야 한다.
        final provider = image.image;
        final asset = provider is ResizeImage
            ? provider.imageProvider as AssetImage
            : provider as AssetImage;
        expect(asset.assetName, 'assets/images/editor_loading_features.png');
        expect(tester.getTopLeft(illustration).dy, greaterThanOrEqualTo(0));
        expect(
          tester.getBottomRight(illustration).dy,
          lessThanOrEqualTo(size.height),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _PendingDownloadApiClient extends ApiClient {
  final pendingUrl = Completer<SignedUrl>();

  @override
  Future<SignedUrl> createDownloadUrl(String id) => pendingUrl.future;
}
