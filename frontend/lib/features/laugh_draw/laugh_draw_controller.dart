import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import 'laugh_draw_models.dart';
import 'laugh_draw_repository.dart';
import 'laugh_draw_sound.dart';
import 'laugh_draw_store.dart';

/// 뽑기 화면의 상태.
///
/// [drawing]·[revealing]이 기존 `loading`을 대신한다 — 로딩 화면 자리에서 뽑기 공이
/// 돌기 때문에 "돌고 있는 중"과 "당첨 공이 떨어지는 중"을 나눠 두면 화면이 연출
/// 단계를 따로 판단하지 않아도 된다.
enum LaughDrawPhase { initial, drawing, revealing, success, empty, error }

/// 반응 영역이 지금 무엇을 할 수 있는 상태인가.
enum LaughReactionMode {
  /// 아직 남긴 반응이 없다. 하나 고르면 저장할 수 있다.
  picking,

  /// 서버에 저장된 반응이 있다. 바꾸려면 편집으로 들어가야 한다.
  saved,

  /// 저장된 반응을 바꾸는 중. 저장하거나 취소할 수 있다.
  editing,
}

/// 웃음 뽑기 진행 상태.
///
/// **연출과 요청을 함께 기다린다**: 서버가 0.3초에 답해도 공이 한 바퀴도 못 돌고
/// 결과가 튀어나오면 뽑기처럼 보이지 않는다. 그래서 요청 완료와 최소 연출 시간
/// 두 조건이 **모두** 끝난 뒤에 결과로 넘어간다. 반대로 서버가 늦으면 연출이
/// 이어서 반복되므로 고정된 `Future.delayed` 하나로 화면을 붙잡아 두지 않는다.
///
/// **오늘 뽑은 결과는 되살린다**: 탭을 옮겼다 돌아오거나 앱을 다시 켜도 오늘 뽑은
/// 추억이 그대로 보여야 한다. 기기에는 날짜와 영상 ID만 남기고([LaughDrawStore]),
/// 화면은 그 ID로 서버에서 다시 읽어 채운다.
class LaughDrawController extends ChangeNotifier {
  LaughDrawController(
    this.familyId,
    this._repository, {
    LaughDrawSoundEffects? sound,
    LaughDrawStore? store,
    this.days = 3,
  }) : sound = sound ?? LaughDrawSound(),
       _store = store ?? LaughDrawStore();

  /// 공이 도는 최소 시간. 이보다 빨리 응답이 와도 연출은 여기까지 이어진다.
  static const minimumDrawDuration = Duration(milliseconds: 1800);

  /// 당첨 공이 떨어져 결과 카드로 넘어가기까지의 마무리 연출.
  static const revealDuration = Duration(milliseconds: 550);

  final String familyId;
  final LaughDrawRepository _repository;
  final LaughDrawStore _store;
  final LaughDrawSoundEffects sound;
  final int days;

  LaughDrawPhase phase = LaughDrawPhase.initial;
  LaughMemory? memory;

  /// 오늘 뽑은 결과를 되살리는 중. 이때는 공을 돌리지도, 소리를 내지도 않는다 —
  /// 사용자가 뽑기를 누른 것이 아니기 때문이다.
  bool restoring = false;

  /// 뽑기 실패 문구(오류 화면용).
  String? errorMessage;

  /// 서버가 준 "꺼낼 영상이 없어요" 문구. 없으면 화면 기본 문구를 쓴다.
  String? emptyMessage;

  /// 반응 저장 요청 중. 이 동안 반응 버튼을 잠근다.
  bool reacting = false;

  /// 반응 실패처럼 화면을 바꾸지 않고 SnackBar로만 알릴 메시지.
  String? lastActionError;

  LaughReactionMode reactionMode = LaughReactionMode.picking;

  /// 화면에서 고른, 아직 저장하지 않은 반응.
  LaughReactionType? pendingReaction;

  /// 이번 화면에서 이미 본 영상. 화면을 닫으면 사라진다(영구 저장하지 않는다).
  final List<String> _viewedMemoryIds = [];

  bool _disposed = false;

  List<String> get viewedMemoryIds => List.unmodifiable(_viewedMemoryIds);

  /// 뽑기 연출이 돌고 있는가. 이 동안 모든 재입력을 막는다.
  bool get isDrawing =>
      phase == LaughDrawPhase.drawing || phase == LaughDrawPhase.revealing;

  bool get canDraw => !isDrawing && !reacting && !restoring;

  /// 결과가 한 번이라도 나온 뒤인가(버튼 문구를 가른다).
  bool get hasResult => phase == LaughDrawPhase.success && memory != null;

  /// 반응 칩을 누를 수 있는가. 저장된 뒤에는 편집으로 들어가야 바꿀 수 있다.
  bool get canPickReaction =>
      !reacting && !isDrawing && reactionMode != LaughReactionMode.saved;

  /// 저장·변경 버튼을 누를 수 있는가.
  bool get canSubmitReaction => !reacting && pendingReaction != null;

  /// 앱을 켜거나 커뮤니티 탭에 들어올 때 한 번. 오늘 뽑은 추억이 있으면 되살린다.
  Future<void> restoreToday() async {
    if (phase != LaughDrawPhase.initial || restoring) return;
    final savedId = await _store.todayMemoryId();
    if (savedId == null || _disposed) return;

    restoring = true;
    _notify();
    try {
      final restored = await _repository.findMemory(savedId);
      if (_disposed) return;
      memory = restored;
      phase = LaughDrawPhase.success;
      // 되살린 영상은 이번 세션에서 이미 본 것으로 둔다 — 다시 뽑기에서 같은
      // 영상이 또 나오지 않게.
      if (!_viewedMemoryIds.contains(restored.id)) {
        _viewedMemoryIds.add(restored.id);
      }
      _syncReactionMode();
    } catch (error) {
      if (_disposed) return;
      // 지워지거나 만료된 영상이면 저장을 버리고 첫 뽑기 화면으로 돌아간다.
      // 네트워크 문제라면 다음 진입에서 다시 시도하도록 저장은 남겨 둔다.
      if (error is ApiFailure && error.statusCode == 404) {
        await _store.clear();
      }
    } finally {
      restoring = false;
      _notify();
    }
  }

  /// 뽑기 한 번. 이미 돌고 있으면 아무 일도 하지 않는다.
  Future<void> draw() async {
    if (isDrawing || restoring) return;

    // 지금 보고 있던 영상은 다음 뽑기에서 빼 달라고 서버에 알린다.
    final current = memory;
    if (current != null && !_viewedMemoryIds.contains(current.id)) {
      _viewedMemoryIds.add(current.id);
    }

    phase = LaughDrawPhase.drawing;
    memory = null;
    errorMessage = null;
    emptyMessage = null;
    lastActionError = null;
    pendingReaction = null;
    reactionMode = LaughReactionMode.picking;
    _notify();

    // 시작음은 기다리지 않는다 — 소리 때문에 공이 늦게 돌면 안 된다.
    sound.playDrawStart();

    // 최소 연출 시간을 **요청보다 먼저** 걸어 둔다. 그래야 요청 시간과 겹쳐
    // 흐르고, 응답이 빠르면 남은 시간만 더 기다린다.
    final minimumElapsed = Future<void>.delayed(minimumDrawDuration);

    Object outcome;
    try {
      outcome = await _repository.drawRandom(
        familyId,
        days: days,
        excludeIds: List.of(_viewedMemoryIds),
      );
    } catch (error) {
      // JSON 파싱 실패까지 여기서 붙잡는다 — 앱이 죽는 대신 오류 화면으로 간다.
      outcome = error;
    }
    await minimumElapsed;
    if (_disposed) return;

    final result = outcome is LaughDrawResult ? outcome : null;

    // 마무리 연출: 당첨 공이 떨어진다. 결과가 비었거나 실패면 소리는 울리지 않고
    // 공만 천천히 멈춘다.
    phase = LaughDrawPhase.revealing;
    _notify();
    if (result != null && result.hasMemory) sound.playDrawComplete();
    await Future<void>.delayed(revealDuration);
    if (_disposed) return;

    if (result == null) {
      errorMessage = _describe(outcome);
      phase = LaughDrawPhase.error;
    } else if (result.hasMemory && result.memory != null) {
      memory = result.memory;
      phase = LaughDrawPhase.success;
      _syncReactionMode();
      // 오늘 뽑은 추억으로 적어 둔다. 탭을 옮기거나 앱을 다시 켜도 이 화면이
      // 되살아난다.
      await _store.saveToday(result.memory!.id);
    } else {
      emptyMessage = result.message;
      phase = LaughDrawPhase.empty;
    }
    _notify();
  }

  /// 반응 칩을 고른다. 아직 서버에는 보내지 않는다.
  void selectReaction(LaughReactionType reaction) {
    if (!canPickReaction) return;
    pendingReaction = reaction;
    lastActionError = null;
    _notify();
  }

  /// 고른 반응을 서버에 저장한다(최초 저장과 변경이 같은 경로다).
  Future<bool> submitReaction() async {
    final current = memory;
    final reaction = pendingReaction;
    if (current == null || reaction == null || reacting || isDrawing) {
      return false;
    }
    reacting = true;
    lastActionError = null;
    _notify();
    try {
      final updated = await _repository.react(current.id, reaction);
      if (_disposed) return false;
      memory = updated;
      _syncReactionMode();
      return true;
    } catch (error) {
      // 실패하면 기존 반응 상태를 그대로 둔다 — 화면에서 숫자가 되돌아가지 않게.
      lastActionError = _describe(error);
      return false;
    } finally {
      reacting = false;
      _notify();
    }
  }

  /// 저장된 반응을 바꾸러 편집으로 들어간다. 서버 반응은 아직 건드리지 않는다.
  void startEditingReaction() {
    if (reactionMode != LaughReactionMode.saved || reacting) return;
    reactionMode = LaughReactionMode.editing;
    pendingReaction = memory?.myReaction;
    lastActionError = null;
    _notify();
  }

  /// 편집을 접는다. 서버 요청 없이 저장돼 있던 반응으로 되돌린다.
  void cancelEditingReaction() {
    if (reactionMode != LaughReactionMode.editing) return;
    reactionMode = LaughReactionMode.saved;
    pendingReaction = memory?.myReaction;
    lastActionError = null;
    _notify();
  }

  /// 서버가 준 `myReaction`에 맞춰 반응 영역의 상태를 정한다.
  void _syncReactionMode() {
    final mine = memory?.myReaction;
    pendingReaction = mine;
    reactionMode = mine == null
        ? LaughReactionMode.picking
        : LaughReactionMode.saved;
  }

  /// 앱이 백그라운드로 가거나 화면이 덮일 때. 울리는 소리를 끊는다.
  /// 기다릴 이유가 없어 결과를 붙잡지 않는다.
  void quiet() {
    sound.stop();
  }

  String _describe(Object error) {
    if (error is ApiFailure) {
      if (error.statusCode == 403) {
        return '이 가족의 추억은 볼 수 없어요. 가족 구성원인지 확인해 주세요.';
      }
      return error.message;
    }
    return '웃음 영상을 불러오지 못했어요.\n잠시 후 다시 시도해 주세요.';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 오디오 플레이어 정리는 네이티브 왕복이라 비동기다. ChangeNotifier.dispose는
    // 기다릴 수 없으니 시작만 시켜 두고 넘어간다.
    sound.dispose();
    super.dispose();
  }
}
