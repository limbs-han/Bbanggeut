/// 자막 상태를 한 곳에 모은다 — 전사 시작, 보관, 수정, 내보내기 변환.
///
/// **왜 컨트롤러인가**: 편집 화면(`local_edit_screen.dart`)은 다른 사람이 계속
/// 고치는 파일이다. 자막 로직을 그 안에 넣으면 나중에 합칠 때 충돌한다. 화면은
/// 이 클래스를 만들고 부르기만 하게 둔다.
library;

import 'package:flutter/foundation.dart';

import 'caption_line.dart';
import 'mlkit_transcriber.dart';
import 'transcript_store.dart';

class CaptionController extends ChangeNotifier {
  CaptionController({TranscriptStore? store})
    : _store = store ?? transcriptStore;

  final TranscriptStore _store;

  ValueListenable<TranscriptJobState>? _job;
  List<CaptionLine> _lines = <CaptionLine>[];
  bool _hasUserEdits = false;

  List<CaptionLine> get lines => _lines;

  TranscriptJobState? get status => _job?.value;

  /// 전사 진행률(0~99). 도는 중이 아니거나 아직 모르면 null.
  ///
  /// 작업이 세는 값이라 시트를 닫았다 열어도 이어진다 — 화면이 세던 동안에는
  /// 다시 열 때마다 1%부터 시작했다.
  int? get percent {
    final state = status;
    if (state is! TranscriptRunning) return null;
    if (state.stage == TranscriptStage.audio || state.percent <= 0) return null;
    return state.percent;
  }

  /// 지금 어느 단계인가. 도는 중이 아니면 null.
  TranscriptStage? get stage {
    final state = status;
    return state is TranscriptRunning ? state.stage : null;
  }

  /// 사용자가 자막을 고쳤는가. 화면이 이 값을 편집 상태의 `hasUnsavedChanges`에
  /// 반영한다 — 전사 결과가 들어온 것만으로는 켜지지 않아야 한다(화면을 열자마자
  /// 폐기 경고가 뜨면 안 된다).
  bool get hasUserEdits => _hasUserEdits;

  /// 전사를 시작한다. 캐시가 있으면 즉시 끝난다. 두 번 불러도 한 번만 돈다.
  void start(String videoId, String videoPath) {
    if (_job != null) return;
    _videoId = videoId;
    _job = _store.ensure(videoId, videoPath)..addListener(_onJobChanged);
    _onJobChanged();
  }

  /// 캐시를 버리고 처음부터 다시 전사한다. 사용자가 "다시 만들기"를 고른
  /// 때만 부른다.
  ///
  /// [start]로는 안 된다 — 한 번 잡은 작업이 있으면 그대로 돌아 나가기
  /// 때문이다. 여기서는 듣던 작업을 놓고, 손으로 고친 줄도 함께 버린다.
  /// 버리는 것이 곧 사용자가 고른 것이다(대화상자가 그렇게 알린다).
  void restart(String videoId, String videoPath) {
    _job?.removeListener(_onJobChanged);
    _videoId = videoId;
    _lines = <CaptionLine>[];
    _hasUserEdits = false;
    _job = _store.restart(videoId, videoPath)..addListener(_onJobChanged);
    _onJobChanged();
  }

  /// [edit]가 캐시 파일에 저장할 때 쓴다. [start]가 채운다.
  String? _videoId;

  void _onJobChanged() {
    final state = _job?.value;
    if (state is TranscriptReady) _lines = state.lines;
    notifyListeners();
  }

  /// 자막 한 줄을 고치고 **캐시 파일에도 바로 저장한다.**
  ///
  /// 파일이 이 영상의 자막 원천이다 — 만화 구성(ComicController)이 이 파일을
  /// 읽고, 다음에 자막을 열 때도 이 파일이 나온다. 메모리에만 두면 사용자가
  /// 자막 탭에서 고친 문장이 만화에는 옛 문장으로 나간다(실사용 지적).
  /// 그래서 편집 화면의 "폐기"를 골라도 자막 수정만은 남는다 — 잘못 고쳤다면
  /// 같은 자리에서 다시 고치면 된다.
  void edit(int index, String text) {
    if (index < 0 || index >= _lines.length) return;
    _lines[index].text = text;
    _hasUserEdits = true;
    final videoId = _videoId;
    if (videoId != null) {
      // 기다리지도, 실패로 죽지도 않는다 — 저장이 안 돼도 메모리 수정은
      // 유지되고 내보내기에는 그대로 반영된다. 잡지 않으면 fire-and-forget
      // Future의 예외가 잡히지 않은 비동기 오류로 터진다.
      pendingWrite = _store.write(videoId, _lines).catchError((Object error) {
        debugPrint('[stt] 자막 수정을 저장하지 못했습니다($videoId): $error');
      });
    }
    notifyListeners();
  }

  /// 테스트가 저장 완료를 기다릴 수 있게 마지막 쓰기 Future를 남긴다.
  @visibleForTesting
  Future<void>? pendingWrite;

  String? textAt(int positionMs) => captionAt(_lines, positionMs);

  List<Map<String, Object>> forExport({
    required int startMs,
    required int endMs,
  }) => captionsForExport(_lines, startMs: startMs, endMs: endMs);

  /// 패널 맨 위 한 줄. 실패해도 자르기·저장은 되어야 하므로 그렇게 안내한다.
  String message({int? estimateSeconds}) {
    final state = status;

    // 모델을 처음 받는 기기는 몇 분이 걸린다. 진행률이 없으면 멈춘 것처럼 보인다.
    final downloading = mlkitDownloadPercent.value;
    if (downloading != null) {
      return '자막 기능을 준비하고 있어요. $downloading%';
    }
    // 자막을 아예 못 만드는 기기라면 기다리게 두지 말고 바로 알린다.
    if (state is! TranscriptReady) {
      switch (mlkitReadiness.value) {
        case MlKitReadiness.needsPermission:
          return '자막을 만들려면 마이크 권한이 필요해요. 설정에서 켜 주세요.';
        case MlKitReadiness.unavailable:
          return '이 기기는 자동 자막을 지원하지 않아요. 자막 없이 저장할 수 있어요.';
        case _:
          break;
      }
    }

    if (state is TranscriptFailed) {
      return '대사를 알아듣지 못했어요. 자막 없이 저장할 수 있어요.';
    }
    if (state is TranscriptRunning) {
      return estimateSeconds == null
          ? '대사를 알아듣고 있어요.'
          : '대사를 알아듣고 있어요. 약 $estimateSeconds초 걸려요.';
    }
    if (state == null) return '자막을 준비하고 있어요.';
    if (_lines.isEmpty) {
      return '대사를 알아듣지 못했어요. 자막 없이 저장할 수 있어요.';
    }
    return '자막 ${_lines.length}줄이에요. 눌러서 고칠 수 있어요.';
  }

  @override
  void dispose() {
    _job?.removeListener(_onJobChanged);
    super.dispose();
  }
}
