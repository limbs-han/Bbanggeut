import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/features/laugh_draw/laugh_draw_controller.dart';
import 'package:william_james_app/features/laugh_draw/laugh_draw_models.dart';
import 'package:william_james_app/features/laugh_draw/laugh_draw_repository.dart';
import 'package:william_james_app/features/laugh_draw/laugh_draw_screen.dart';
import 'package:william_james_app/features/laugh_draw/laugh_draw_sound.dart';
import 'package:william_james_app/features/laugh_draw/laugh_draw_store.dart';
import 'package:william_james_app/ui/main_shell.dart';

/// 소리는 내지 않고 호출만 세는 효과음. 테스트에서 네이티브 오디오 플레이어를
/// 붙잡지 않으려고 컨트롤러에 넣어 준다.
class _SilentSound implements LaughDrawSoundEffects {
  int startCount = 0;
  int completeCount = 0;
  int stopCount = 0;

  @override
  Future<void> playDrawStart() async => startCount++;
  @override
  Future<void> playDrawComplete() async => completeCount++;
  @override
  Future<void> stop() async => stopCount++;
  @override
  Future<void> dispose() async {}
}

/// 넘겨받은 excludeIds와 호출 횟수를 기록하는 저장소.
class _FakeRepository implements LaughDrawRepository {
  _FakeRepository({this.result, this.failure, this.delay = Duration.zero});

  LaughDrawResult? result;
  Object? failure;
  Duration delay;
  int drawCount = 0;
  final List<List<String>> excludeCalls = [];
  final List<LaughReactionType> reactions = [];

  /// 복원(findMemory)용. 별도로 지정하지 않으면 기본 추억을 돌려준다.
  LaughMemory? restored;
  Object? restoreFailure;
  final List<String> findCalls = [];

  @override
  Future<LaughDrawResult> drawRandom(
    String familyId, {
    int days = 3,
    List<String> excludeIds = const [],
  }) async {
    drawCount++;
    excludeCalls.add(List.of(excludeIds));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final error = failure;
    if (error != null) throw error;
    return result!;
  }

  @override
  Future<LaughMemory> findMemory(String memoryId) async {
    findCalls.add(memoryId);
    final error = restoreFailure ?? failure;
    if (error != null) throw error;
    return restored ?? _memory(id: memoryId);
  }

  @override
  Future<LaughMemory> react(String memoryId, LaughReactionType reaction) async {
    reactions.add(reaction);
    final error = failure;
    if (error != null) throw error;
    return _memory(
      id: memoryId,
      counts: {reaction: 1},
      mine: reaction,
      family: [
        LaughReactionMember(
          memberId: 'u1',
          displayName: '엄마',
          reaction: reaction,
          isMe: true,
        ),
      ],
    );
  }
}

/// 오늘 뽑은 영상 ID를 메모리에만 들고 있는 저장소.
class _FakeStore extends LaughDrawStore {
  _FakeStore({this.savedId, this.savedDay});

  String? savedId;
  String? savedDay;
  int clearCount = 0;

  @override
  Future<String?> todayMemoryId({DateTime? now}) async =>
      savedDay == LaughDrawStore.dayKey(now ?? DateTime.now()) ? savedId : null;

  @override
  Future<void> saveToday(String memoryId, {DateTime? now}) async {
    savedId = memoryId;
    savedDay = LaughDrawStore.dayKey(now ?? DateTime.now());
  }

  @override
  Future<void> clear() async {
    clearCount++;
    savedId = null;
    savedDay = null;
  }
}

LaughMemory _memory({
  String id = 'video-1',
  Map<LaughReactionType, int> counts = const {},
  LaughReactionType? mine,
  List<LaughReactionMember> family = const [],
}) => LaughMemory(
  video: VideoMemory(
    id: id,
    deviceId: 'device-1',
    triggerType: 'LAUGHTER',
    eventTypes: const ['LAUGHTER'],
    title: '아빠의 이상한 춤',
    status: 'READY',
    favorite: false,
    durationMs: 42000,
    capturedStartAt: DateTime(2026, 8, 5, 20, 35),
    createdAt: DateTime(2026, 8, 5, 20, 35),
  ),
  expiresAt: DateTime(2026, 8, 12, 20, 35),
  reactionCounts: counts,
  myReaction: mine,
  familyReactions: family,
);

AppController _app() {
  const vault = MemoryVault(
    id: 'vault-1',
    name: '우리 집',
    status: 'ACTIVE',
    myRole: 'OWNER',
    retentionDays: 7,
    subscriptionActive: false,
    devices: [],
  );
  return AppController()
    ..user = const UserProfile(id: 'u1', email: 'a@b.com', displayName: '엄마')
    ..vaults = const [vault]
    ..selectedVault = vault;
}

/// 뽑기 연출 하나가 끝날 만큼 가상 시간을 흘린다.
Future<void> _finishDraw(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

void main() {
  group('LaughDrawModels', () {
    test('서버 응답을 뽑기 결과로 읽는다', () {
      final result = LaughDrawResult.fromJson({
        'hasMemory': true,
        'memory': {
          'video': {
            'id': 'video-9',
            'deviceId': 'device-1',
            'triggerType': 'LAUGHTER',
            'eventTypes': ['LAUGHTER', 'CLAP'],
            'title': '우리 가족의 웃음',
            'status': 'READY',
            'isFavorite': false,
            'capturedStartAt': '2026-08-04T20:35:00Z',
          },
          'expiresAt': '2026-08-11T20:35:00Z',
          // 서버가 모르는 종류를 보내도 무시하고 나머지를 읽는다.
          'reactionCounts': {'FUNNY': 3, 'AGAIN': 0, 'UNKNOWN': 9},
          'myReaction': 'FUNNY',
        },
      });

      expect(result.hasMemory, isTrue);
      expect(result.memory!.video.id, 'video-9');
      expect(result.memory!.countOf(LaughReactionType.funny), 3);
      expect(result.memory!.countOf(LaughReactionType.missThis), 0);
      expect(result.memory!.myReaction, LaughReactionType.funny);
      expect(result.memory!.expiresAt, isNotNull);
    });

    test('영상이 없으면 빈 결과로 읽는다', () {
      final result = LaughDrawResult.fromJson({
        'hasMemory': false,
        'memory': null,
        'message': '최근 3일간 저장된 웃음 영상이 없어요.',
      });

      expect(result.hasMemory, isFalse);
      expect(result.memory, isNull);
      expect(result.message, contains('최근 3일'));
    });
  });

  group('LaughDrawController', () {
    testWidgets('응답이 빨라도 최소 연출 시간을 지킨 뒤 결과로 넘어간다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
        delay: const Duration(milliseconds: 100),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      await tester.pump(const Duration(milliseconds: 150));
      expect(controller.phase, LaughDrawPhase.drawing);

      // 최소 연출 시간(1.8초)이 끝나야 마무리 연출로 넘어간다.
      await tester.pump(const Duration(milliseconds: 1700));
      expect(controller.phase, LaughDrawPhase.revealing);

      await tester.pump(LaughDrawController.revealDuration);
      expect(controller.phase, LaughDrawPhase.success);
      expect(controller.memory, isNotNull);
    });

    testWidgets('응답이 늦으면 응답이 온 뒤에 결과로 넘어간다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
        delay: const Duration(seconds: 4),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      await tester.pump(const Duration(milliseconds: 2500));
      expect(controller.phase, LaughDrawPhase.drawing);

      await tester.pump(const Duration(seconds: 2));
      expect(controller.phase, LaughDrawPhase.revealing);
      await tester.pump(LaughDrawController.revealDuration);
      expect(controller.phase, LaughDrawPhase.success);
    });

    testWidgets('연출 중 다시 누르면 요청이 겹치지 않는다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      controller.draw();
      await tester.pump(const Duration(milliseconds: 500));
      controller.draw();
      await _finishDraw(tester);

      expect(repository.drawCount, 1);
    });

    testWidgets('다시 뽑으면 방금 본 영상을 excludeIds로 넘긴다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(
          hasMemory: true,
          memory: _memory(id: 'video-a'),
        ),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);
      controller.draw();
      await _finishDraw(tester);

      expect(repository.excludeCalls.first, isEmpty);
      expect(repository.excludeCalls.last, ['video-a']);
      expect(controller.viewedMemoryIds, ['video-a']);
    });

    testWidgets('빈 결과와 실패는 연출을 끝낸 뒤 각자의 상태가 된다', (tester) async {
      final repository = _FakeRepository(
        result: const LaughDrawResult(hasMemory: false, message: '없어요'),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);
      expect(controller.phase, LaughDrawPhase.empty);
      expect(controller.emptyMessage, '없어요');

      repository.failure = const ApiFailure('서버가 아파요', statusCode: 500);
      controller.draw();
      await tester.pump(const Duration(milliseconds: 500));
      // 실패해도 연출은 최소 시간까지 이어진다.
      expect(controller.phase, LaughDrawPhase.drawing);
      await _finishDraw(tester);
      expect(controller.phase, LaughDrawPhase.error);
      expect(controller.errorMessage, '서버가 아파요');
    });

    testWidgets('403은 접근 불가 안내로 바뀐다', (tester) async {
      final repository = _FakeRepository(
        failure: const ApiFailure('거부', statusCode: 403),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);

      expect(controller.errorMessage, contains('가족 구성원'));
    });

    testWidgets('반응은 고른 뒤 버튼을 눌러야 저장된다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: _FakeStore(),
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);

      // 아직 고르지 않았으니 저장 버튼은 잠겨 있다.
      expect(controller.reactionMode, LaughReactionMode.picking);
      expect(controller.canSubmitReaction, isFalse);

      controller.selectReaction(LaughReactionType.funny);
      await tester.pump();
      expect(controller.canSubmitReaction, isTrue);
      // 고르기만 했으므로 서버에는 아직 아무것도 가지 않았다.
      expect(repository.reactions, isEmpty);

      controller.submitReaction();
      await tester.pump();
      expect(repository.reactions, [LaughReactionType.funny]);
      expect(controller.reactionMode, LaughReactionMode.saved);
      expect(controller.memory!.myReaction, LaughReactionType.funny);
      expect(controller.memory!.countOf(LaughReactionType.funny), 1);
      expect(controller.memory!.familyReactions.single.displayName, '엄마');
      // 저장된 뒤에는 칩을 눌러 바로 바꿀 수 없다.
      expect(controller.canPickReaction, isFalse);
    });

    testWidgets('반응 다시 고르기로 바꾸고, 취소하면 저장된 반응으로 돌아온다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: _FakeStore(),
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);
      controller.selectReaction(LaughReactionType.funny);
      controller.submitReaction();
      await tester.pump();

      controller.startEditingReaction();
      await tester.pump();
      expect(controller.reactionMode, LaughReactionMode.editing);
      // 편집에 들어가도 저장된 반응이 기본 선택이다.
      expect(controller.pendingReaction, LaughReactionType.funny);
      expect(controller.canPickReaction, isTrue);

      controller.selectReaction(LaughReactionType.again);
      await tester.pump();
      controller.cancelEditingReaction();
      await tester.pump();
      // 취소는 서버로 나가지 않고 저장돼 있던 반응으로 되돌린다.
      expect(repository.reactions, [LaughReactionType.funny]);
      expect(controller.reactionMode, LaughReactionMode.saved);
      expect(controller.pendingReaction, LaughReactionType.funny);

      controller.startEditingReaction();
      controller.selectReaction(LaughReactionType.again);
      controller.submitReaction();
      await tester.pump();
      expect(repository.reactions, [
        LaughReactionType.funny,
        LaughReactionType.again,
      ]);
      expect(controller.reactionMode, LaughReactionMode.saved);
      expect(controller.memory!.myReaction, LaughReactionType.again);
    });

    testWidgets('반응 저장이 실패하면 기존 상태를 지킨다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: _FakeStore(),
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);
      controller.selectReaction(LaughReactionType.funny);
      controller.submitReaction();
      await tester.pump();

      repository.failure = const ApiFailure('반응 실패');
      controller.startEditingReaction();
      controller.selectReaction(LaughReactionType.again);
      controller.submitReaction();
      await tester.pump();

      expect(controller.memory!.myReaction, LaughReactionType.funny);
      expect(controller.lastActionError, '반응 실패');
    });

    testWidgets('오늘 뽑았으면 다시 들어와도 저장된 영상으로 결과를 되살린다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(
          hasMemory: true,
          memory: _memory(id: 'today-1'),
        ),
      );
      final store = _FakeStore();
      final first = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: store,
      );
      addTearDown(first.dispose);

      first.draw();
      await _finishDraw(tester);
      // 뽑고 나면 오늘 날짜와 영상 ID가 기기에 남는다.
      expect(store.savedId, 'today-1');
      expect(store.savedDay, LaughDrawStore.dayKey(DateTime.now()));

      // 탭을 옮겼다 돌아온 것처럼 컨트롤러를 새로 만든다.
      repository.restored = _memory(
        id: 'today-1',
        counts: {LaughReactionType.goodSave: 2},
        mine: LaughReactionType.goodSave,
        family: const [
          LaughReactionMember(
            memberId: 'u2',
            displayName: '아빠',
            reaction: LaughReactionType.goodSave,
            isMe: false,
          ),
        ],
      );
      final second = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: store,
      );
      addTearDown(second.dispose);

      await second.restoreToday();
      await tester.pump();

      expect(repository.findCalls, ['today-1']);
      expect(second.phase, LaughDrawPhase.success);
      expect(second.memory!.id, 'today-1');
      // 반응은 저장된 화면이 아니라 서버의 최신 값으로 채운다.
      expect(second.memory!.countOf(LaughReactionType.goodSave), 2);
      expect(second.reactionMode, LaughReactionMode.saved);
      expect(second.memory!.familyReactions.single.displayName, '아빠');
      // 되살린 영상은 다시 뽑기에서 제외된다.
      expect(second.viewedMemoryIds, ['today-1']);
    });

    testWidgets('어제 뽑은 기록은 되살리지 않는다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final store = _FakeStore(
        savedId: 'yesterday-1',
        savedDay: LaughDrawStore.dayKey(
          DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.restoreToday();
      await tester.pump();

      expect(repository.findCalls, isEmpty);
      expect(controller.phase, LaughDrawPhase.initial);
    });

    testWidgets('저장된 영상이 사라졌으면 기록을 지우고 첫 화면으로 돌아간다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      )..restoreFailure = const ApiFailure('없음', statusCode: 404);
      final store = _FakeStore(
        savedId: 'gone-1',
        savedDay: LaughDrawStore.dayKey(DateTime.now()),
      );
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.restoreToday();
      await tester.pump();

      expect(controller.phase, LaughDrawPhase.initial);
      expect(store.clearCount, 1);
      expect(store.savedId, isNull);
    });

    testWidgets('네트워크 오류로 되살리지 못하면 기록은 남겨 둔다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      )..restoreFailure = const ApiFailure('연결 실패');
      final store = _FakeStore(
        savedId: 'keep-1',
        savedDay: LaughDrawStore.dayKey(DateTime.now()),
      );
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: _SilentSound(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.restoreToday();
      await tester.pump();

      expect(controller.phase, LaughDrawPhase.initial);
      expect(store.clearCount, 0);
      expect(store.savedId, 'keep-1');
    });

    testWidgets('효과음은 시작과 당첨에 한 번씩만 울린다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      // 연출 중 연속 탭이 효과음을 겹치게 하지 않는다.
      controller.draw();
      await _finishDraw(tester);

      expect(sound.startCount, 1);
      expect(sound.completeCount, 1);
    });

    testWidgets('영상이 없거나 실패하면 당첨 효과음을 울리지 않는다', (tester) async {
      final repository = _FakeRepository(
        result: const LaughDrawResult(hasMemory: false),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.draw();
      await _finishDraw(tester);
      expect(sound.startCount, 1);
      expect(sound.completeCount, 0);

      repository.failure = const ApiFailure('서버가 아파요');
      controller.draw();
      await _finishDraw(tester);
      expect(sound.completeCount, 0);
    });

    testWidgets('화면을 벗어나면 소리를 끊는다', (tester) async {
      final repository = _FakeRepository(
        result: LaughDrawResult(hasMemory: true, memory: _memory()),
      );
      final sound = _SilentSound();
      final controller = LaughDrawController(
        'vault-1',
        repository,
        sound: sound,
      );
      addTearDown(controller.dispose);

      controller.quiet();
      await tester.pump();

      expect(sound.stopCount, 1);
    });
  });

  testWidgets('Galaxy S24+ 폭에서 뽑기 화면이 넘치지 않고 초기 상태가 보인다', (tester) async {
    tester.view.physicalSize = const Size(1440, 3120);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = _app();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: LaughDrawScreen(app: app),
      ),
    );

    expect(find.byKey(const Key('laugh-draw-button')), findsOneWidget);
    expect(find.text('오늘은 어떤 영상이 나올까?'), findsOneWidget);
    expect(find.text('최근 3일간 저장된 우리 가족의 웃음 중\n하나를 랜덤으로 꺼내봐요!'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('커뮤니티 탭을 누르면 빵긋이 화면이 아니라 뽑기 화면이 바로 나온다', (tester) async {
    tester.view.physicalSize = const Size(1440, 3120);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = _app()..selectedDevice = _device;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MainShell(controller: app),
      ),
    );
    await tester.tap(find.text('커뮤니티'));
    await tester.pump();

    expect(find.byType(LaughDrawScreen), findsOneWidget);
    expect(find.text('우리집 빵긋이'), findsNothing);
    // 한 번 더 눌러 들어가야 하는 진입 카드가 없어야 한다.
    expect(find.byKey(const Key('laugh-draw-entry')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

const _device = DeviceSummary(
  id: 'device-1',
  name: '거실 홈캠',
  model: 'test',
  status: 'ONLINE',
  myRole: 'OWNER',
  retentionDays: 7,
);
