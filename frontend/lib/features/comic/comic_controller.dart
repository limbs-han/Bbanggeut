/// 만화 만들기 상태 — 전사문 → 구성 → 그림.
///
/// 화면은 이 클래스를 만들고 부르기만 한다. 상태 전이가 여기 모여 있어서 화면을
/// 띄우지 않고 전부 검증할 수 있다.
library;

import 'package:flutter/foundation.dart';

import '../stt/caption_line.dart';
import '../stt/transcript_store.dart' as stt;
import 'comic_gateway.dart';
import 'comic_script.dart';

sealed class ComicState {
  const ComicState();
}

/// 자막(전사문)이 없다. 만화를 만들 수 없다.
class ComicNeedsTranscript extends ComicState {
  const ComicNeedsTranscript();
}

class ComicLoadingScript extends ComicState {
  const ComicLoadingScript();
}

class ComicScriptReady extends ComicState {
  const ComicScriptReady(this.cuts);
  final List<ComicCut> cuts;
}

class ComicLoadingImage extends ComicState {
  const ComicLoadingImage(this.cuts);
  final List<ComicCut> cuts;
}

class ComicReady extends ComicState {
  const ComicReady(this.cuts, this.image);
  final List<ComicCut> cuts;
  final Uint8List image;
}

/// 실패했지만 구성이 있으면 함께 들고 있는다 — 고친 대사를 잃지 않기 위해서다.
class ComicFailed extends ComicState {
  const ComicFailed(this.reason, this.cuts);
  final String reason;
  final List<ComicCut>? cuts;
}

class ComicController extends ChangeNotifier {
  ComicController({
    required this.gateway,
    required this.videoId,
    stt.TranscriptStore? store,
  }) : _store = store ?? stt.transcriptStore;

  final ComicGateway gateway;
  final String videoId;
  final stt.TranscriptStore _store;

  ComicState _state = const ComicLoadingScript();
  List<ComicCut> _cuts = <ComicCut>[];

  ComicState get state => _state;

  /// 지금 들고 있는 구성. 없으면 빈 목록.
  List<ComicCut> get cuts => _cuts;

  void _set(ComicState next) {
    _state = next;
    notifyListeners();
  }

  /// 자막에서 만든 전사문을 읽어 구성을 받는다. **전사를 다시 돌리지 않는다.**
  Future<void> start() async {
    _set(const ComicLoadingScript());
    final List<CaptionLine>? lines;
    try {
      lines = await _store.read(videoId);
    } catch (error) {
      _set(ComicFailed('$error', null));
      return;
    }
    if (lines == null || lines.isEmpty) {
      _set(const ComicNeedsTranscript());
      return;
    }

    try {
      _cuts = await gateway.script(videoId, lines);
      _set(ComicScriptReady(_cuts));
    } catch (error) {
      _set(ComicFailed('$error', null));
    }
  }

  /// 빈 글이면 null로 둔다 — 빈 자막 띠를 그리지 않는다.
  void editDialogue(int index, String? text) {
    if (index < 0 || index >= _cuts.length) return;
    final trimmed = text?.trim();
    _cuts[index].dialogue = (trimmed == null || trimmed.isEmpty)
        ? null
        : trimmed;
    notifyListeners();
  }

  /// 완성된 만화에서 컷 목록으로 되돌린다 — 대사를 고쳐 다시 만들려는 경우다.
  ///
  /// **구성을 다시 받지 않는다.** 구성 요청은 호출마다 돈이 들고, 새로 받으면 서버가
  /// 준 원문이 사용자가 고친 대사를 덮어쓴다. 들고 있는 _cuts를 그대로 다시 보여준다.
  void backToCuts() {
    if (_cuts.isEmpty) return;
    _set(ComicScriptReady(_cuts));
  }

  /// 실패해도 _cuts를 그대로 둔다 — 사용자가 고친 것을 잃으면 처음부터 다시
  /// 고쳐야 한다.
  Future<void> makeImage() async {
    if (_cuts.isEmpty) return;
    _set(ComicLoadingImage(_cuts));
    try {
      final bytes = await gateway.image(videoId, _cuts);
      _set(ComicReady(_cuts, bytes));
    } catch (error) {
      _set(ComicFailed('$error', _cuts));
    }
  }
}
