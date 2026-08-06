/// 만화 피드.
///
/// 그림은 화면에 들어온 카드만 받고, 좋아요는 누른 즉시 반응하며 실패하면
/// 되돌아간다. 목록 전체를 다시 받지 않는 것이 이 화면의 요지다 — 다시 받으면
/// 스크롤이 튀어 방금 보던 만화를 잃는다.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/features/comic/comic_feed.dart';
import 'package:william_james_app/features/comic/comic_gateway.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/stt/caption_line.dart';

/// 좋아요만 받아 세는 가짜. ApiClient는 Dio를 들고 있어 통째로 대역을 만들 수
/// 없으므로, 화면이 실제로 부르는 것만 덮어쓴다.
class _FakeApi extends ApiClient {
  _FakeApi({this.fail = false});

  final bool fail;
  final List<bool> calls = [];
  int likeCount = 2;

  @override
  Future<({int likeCount, bool likedByMe})> setComicLiked(
    String videoId,
    bool liked,
  ) async {
    calls.add(liked);
    if (fail) throw const ApiFailure('서버 없음');
    likeCount += liked ? 1 : -1;
    return (likeCount: likeCount, likedByMe: liked);
  }
}

VaultComic comic({
  String videoId = 'v1',
  String title = '우리집 만화',
  int likeCount = 2,
  bool likedByMe = false,
  int commentCount = 3,
  bool canDelete = false,
}) => VaultComic(
  videoId: videoId,
  title: title,
  customTitle: true,
  madeAt: DateTime.utc(2026, 8, 5, 12),
  likeCount: likeCount,
  likedByMe: likedByMe,
  commentCount: commentCount,
  canDelete: canDelete,
);

/// 만화가 아직 없는 서버. 그림을 청해도 네트워크를 건드리지 않는다 — 실제
/// 기기에서도 그림은 늘 늦게 오므로, 카드는 그림 없이 온전히 서야 한다.
class _EmptyGateway implements ComicGateway {
  @override
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines) async =>
      const [];

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async => Uint8List(0);

  @override
  Future<ComicJobStatus> enqueueImage(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async => const ComicJobStatus(status: 'none');

  @override
  Future<ComicJobStatus> jobStatus(String videoId) async =>
      const ComicJobStatus(status: 'none');

  @override
  Future<Uint8List> download(String imageUrl) async => Uint8List(0);
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required ApiClient api,
    List<VaultComic> comics = const [],
  }) async {
    // 만화 한 장이 화면 폭의 정사각이라 기본 테스트 화면(800x600)에서는 아래
    // 버튼 줄이 밖으로 밀린다. 실제 폰에 가까운 세로 화면으로 둔다.
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicFeed(
            api: api,
            comics: comics,
            videoById: (_) => null,
            gateway: _EmptyGateway(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('만화가 없으면 안내를 보여 준다', (tester) async {
    await pump(tester, api: _FakeApi());

    expect(find.text('만든 만화가 없어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-feed')), findsNothing);
  });

  /// 지울 수 있는지는 서버가 만화마다 판정한다(만든 사람 또는 OWNER). 앱이
  /// 역할로 다시 계산하면 규칙이 두 곳에 생겨 서버와 어긋난다.
  testWidgets('지울 수 없는 만화에는 삭제 버튼이 없다', (tester) async {
    await pump(tester, api: _FakeApi(), comics: [comic()]);

    expect(find.byKey(const ValueKey('comic-delete-v1')), findsNothing);
  });

  testWidgets('지울 수 있는 만화에만 삭제 버튼이 뜬다', (tester) async {
    await pump(tester, api: _FakeApi(), comics: [comic(canDelete: true)]);

    expect(find.byKey(const ValueKey('comic-delete-v1')), findsOneWidget);
  });

  /// 되돌릴 수 없는 동작이다. 물어보지 않고 지우면 잘못 누른 손가락 하나로
  /// 가족이 단 좋아요와 댓글까지 사라진다.
  testWidgets('삭제는 확인을 먼저 묻는다', (tester) async {
    await pump(tester, api: _FakeApi(), comics: [comic(canDelete: true)]);

    await tester.tap(find.byKey(const ValueKey('comic-delete-v1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('comic-delete-dialog')), findsOneWidget);
    expect(find.text('취소'), findsOneWidget);
  });

  testWidgets('제목·날짜·좋아요·댓글 수를 한 카드에 보여 준다', (tester) async {
    await pump(tester, api: _FakeApi(), comics: [comic()]);

    expect(find.text('우리집 만화'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: '좋아요 수');
    expect(find.text('3'), findsOneWidget, reason: '댓글 수');
    expect(find.byKey(const ValueKey('comic-card-v1')), findsOneWidget);
  });

  // 좋아요는 누른 즉시 반응해야 한다. 서버 왕복을 기다리면 눌러도 아무 일이
  // 없는 것처럼 보인다.
  testWidgets('좋아요를 누르면 곧바로 숫자가 오른다', (tester) async {
    final api = _FakeApi();
    await pump(tester, api: api, comics: [comic()]);

    await tester.tap(find.byKey(const ValueKey('comic-like-v1')));
    await tester.pump();

    expect(find.text('3'), findsNWidgets(2), reason: '좋아요 3 · 댓글 3');
    await tester.pumpAndSettle();
    expect(api.calls, [true]);
  });

  testWidgets('좋아요가 실패하면 눌렀던 것을 되돌린다', (tester) async {
    await pump(
      tester,
      api: _FakeApi(fail: true),
      comics: [comic(likeCount: 5, likedByMe: true)],
    );

    await tester.tap(find.byKey(const ValueKey('comic-like-v1')));
    await tester.pumpAndSettle();

    expect(find.text('5'), findsOneWidget, reason: '실패했으니 5로 돌아온다');
  });

  testWidgets('이미 누른 좋아요는 다시 누르면 취소된다', (tester) async {
    final api = _FakeApi();
    await pump(tester, api: api, comics: [comic(likedByMe: true)]);

    await tester.tap(find.byKey(const ValueKey('comic-like-v1')));
    await tester.pumpAndSettle();

    expect(api.calls, [false]);
  });

  testWidgets('그림이 오기 전에도 카드 높이가 정해져 있다', (tester) async {
    // 그림이 도착할 때 카드 크기가 바뀌면 스크롤 중에 아래 카드들이 튀어 오른다.
    await pump(tester, api: _FakeApi(), comics: [comic()]);

    expect(find.byType(AspectRatio), findsOneWidget);
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      1,
      reason: '만화는 2x2 정사각이다',
    );
  });

  testWidgets('제목 바꾸기 버튼이 카드마다 있다', (tester) async {
    await pump(tester, api: _FakeApi(), comics: [comic(), comic(videoId: 'v2')]);

    expect(find.byKey(const ValueKey('comic-rename-v1')), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-rename-v2')), findsOneWidget);
  });
}

