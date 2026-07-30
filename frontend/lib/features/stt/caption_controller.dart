/// 자막 상태를 한 곳에 모은다 — 전사 시작, 보관, 수정, 내보내기 변환.
///
/// **왜 컨트롤러인가**: 편집 화면(`local_edit_screen.dart`)은 다른 사람이 계속
/// 고치는 파일이다. 자막 로직을 그 안에 넣으면 나중에 합칠 때 충돌한다. 화면은
/// 이 클래스를 만들고 부르기만 하게 둔다.
library;

import 'package:flutter/foundation.dart';

import 'caption_line.dart';
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

  /// 사용자가 자막을 고쳤는가. 화면이 이 값을 편집 상태의 `hasUnsavedChanges`에
  /// 반영한다 — 전사 결과가 들어온 것만으로는 켜지지 않아야 한다(화면을 열자마자
  /// 폐기 경고가 뜨면 안 된다).
  bool get hasUserEdits => _hasUserEdits;

  /// 전사를 시작한다. 캐시가 있으면 즉시 끝난다. 두 번 불러도 한 번만 돈다.
  void start(String videoId, String videoPath) {
    if (_job != null) return;
    _job = _store.ensure(videoId, videoPath)..addListener(_onJobChanged);
    _onJobChanged();
  }

  void _onJobChanged() {
    final state = _job?.value;
    if (state is TranscriptReady) _lines = state.lines;
    notifyListeners();
  }

  void edit(int index, String text) {
    if (index < 0 || index >= _lines.length) return;
    _lines[index].text = text;
    _hasUserEdits = true;
    notifyListeners();
  }

  String? textAt(int positionMs) => captionAt(_lines, positionMs);

  List<Map<String, Object>> forExport({
    required int startMs,
    required int endMs,
  }) => captionsForExport(_lines, startMs: startMs, endMs: endMs);

  /// 패널 맨 위 한 줄. 실패해도 자르기·저장은 되어야 하므로 그렇게 안내한다.
  String message({int? estimateSeconds}) {
    final state = status;
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
