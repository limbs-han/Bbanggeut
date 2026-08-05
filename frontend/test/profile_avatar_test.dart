import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/ui/profile_avatar.dart';

/// 지금 그려진 아바타의 에셋 이름. `cacheWidth`를 주면 [ResizeImage]로 한 겹
/// 싸이므로 안쪽 provider까지 벗겨 본다.
String drawnAsset(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  final provider = image.image;
  final inner = provider is ResizeImage ? provider.imageProvider : provider;
  return (inner as AssetImage).assetName;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('아바타를 바꾸면 const로 박힌 아바타 자리도 다시 그려진다', (tester) async {
    // 설정 화면의 작은 아바타는 `const ProfileAvatarView(radius: 24)`다. const
    // 위젯은 부모가 setState를 불러도 Flutter가 같은 인스턴스를 알아보고 서브트리
    // 리빌드를 건너뛴다 — 저장소를 build 안에서 읽던 시절에는 새로 고른 그림이
    // 그 자리에 영영 반영되지 않았다. 부모 리빌드 없이도 반영되는지 본다.
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ProfileAvatarView(radius: 24))),
    );
    await tester.pumpAndSettle();

    expect(drawnAsset(tester), ProfileAvatarStore.fallback.value);

    const chosen = ProfileAvatarSelection.asset(
      'assets/images/profile_avatar_teddy.png',
    );
    await ProfileAvatarStore.save(chosen);
    await tester.pump();

    expect(drawnAsset(tester), 'assets/images/profile_avatar_teddy.png');
  });
}
