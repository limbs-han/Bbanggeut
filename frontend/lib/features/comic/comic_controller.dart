/// 만화 만들기 상태 — 전사문 → 구성 → 그림.
///
/// 화면은 이 클래스를 만들고 부르기만 한다. 상태 전이가 여기 모여 있어서 화면을
/// 띄우지 않고 전부 검증할 수 있다.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../stt/caption_line.dart';
import '../stt/transcript_store.dart' as stt;
import 'comic_gateway.dart';
import 'comic_script.dart';

sealed class ComicState {
  const ComicState();
}

/// 자막(전사문)이 없다. 만화를 만들 수 없다.
///
/// 여기서 끝이 아니다 — [ComicController.transcribe]로 이 화면에서 바로 자막을
/// 만들 수 있다. 예전에는 "편집 화면에서 자막을 열어 주세요"라고만 안내했는데,
/// 만화를 만들려던 사람을 다른 화면으로 보내 놓고 돌아오게 하는 길이었다.
class ComicNeedsTranscript extends ComicState {
  const ComicNeedsTranscript();
}

/// 이 화면에서 자막을 만들고 있다. 원본 내려받기와 전사를 함께 나타낸다.
///
/// [percent]가 null이면 진행률을 모르는 단계다(원본 내려받기 시작 전 등).
class ComicTranscribing extends ComicState {
  const ComicTranscribing(this.label, {this.percent});

  /// 지금 무엇을 하는 중인지. 화면이 그대로 보여 준다.
  final String label;
  final int? percent;
}

class ComicLoadingScript extends ComicState {
  const ComicLoadingScript();
}

class ComicScriptReady extends ComicState {
  const ComicScriptReady(this.cuts);
  final List<ComicCut> cuts;
}

/// 그림을 서버가 만들고 있다. 화면을 벗어나도 계속되고 끝나면 알림이 온다.
///
/// [queuePosition]이 0보다 크면 아직 순서를 기다리는 중이다 — 사용자에게
/// "몇 번째"를 보여 줄 수 있어야 무작정 기다리지 않는다.
class ComicLoadingImage extends ComicState {
  const ComicLoadingImage(this.cuts, {this.queuePosition = 0});
  final List<ComicCut> cuts;
  final int queuePosition;
}

/// 전에 만들어 둔 만화가 서버에 있는데 **구성을 함께 받지 못했다.**
///
/// 서버가 구성(script.json)을 남기기 전에 만든 옛 만화만 이 상태로 온다. 구성이
/// 없으면 자막 띠를 얹을 수 없어 그림만 보여 주고, 대사를 되살리려면 구성을
/// 새로 받아야 한다. 구성이 함께 왔으면 [ComicReady]로 간다 — 그래야 대사와
/// 저장·공유 버튼이 그대로 있다.
class ComicSaved extends ComicState {
  const ComicSaved(this.image, this.savedAt);
  final Uint8List image;
  final DateTime? savedAt;
}

/// 그림과 구성이 모두 손에 있다. 자막 띠를 얹어 보여 주고 저장·공유할 수 있다.
///
/// [savedAt]은 서버에 저장된 만화를 다시 열었을 때만 있다 — 방금 만든 것은 null.
class ComicReady extends ComicState {
  const ComicReady(this.cuts, this.image, {this.savedAt});
  final List<ComicCut> cuts;
  final Uint8List image;
  final DateTime? savedAt;
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
    this.sourceProvider,
    stt.TranscriptStore? store,
  }) : _store = store ?? stt.transcriptStore;

  final ComicGateway gateway;
  final String videoId;
  final stt.TranscriptStore _store;

  /// 원본 영상을 기기에 내려놓고 그 경로를 주는 통로. 자막을 이 화면에서 만들 때
  /// 쓴다 — 전사는 로컬 파일이 있어야 돌아간다. null이면 자막 만들기를 걸지
  /// 않는다(화면이 버튼을 감춘다).
  final Future<String> Function(void Function(int percent) onProgress)?
  sourceProvider;

  ComicState _state = const ComicLoadingScript();
  List<ComicCut> _cuts = <ComicCut>[];

  /// 진행 상황 폴링. 화면이 닫히면 멈춘다.
  static const _pollInterval = Duration(seconds: 3);
  Timer? _pollTimer;
  bool _disposed = false;

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

  /// 자막이 없을 때 **이 화면에서** 자막을 만든다. 끝나면 곧바로 구성을 받는다.
  ///
  /// 편집 화면으로 보내지 않는 이유: 만화를 만들려고 들어온 사람에게 다른
  /// 화면을 거쳐 돌아오라고 하는 길이었다. 전사는 로컬 원본이 있어야 도니까
  /// [sourceProvider]로 먼저 내려받는다.
  Future<void> transcribe() async {
    final provider = sourceProvider;
    if (provider == null) return;
    _set(const ComicTranscribing('영상을 불러오고 있어요'));
    final String path;
    try {
      path = await provider((percent) {
        if (!_disposed) {
          _set(ComicTranscribing('영상을 불러오고 있어요', percent: percent));
        }
      });
    } catch (error) {
      _set(ComicFailed('$error', null));
      return;
    }
    if (_disposed) return;
    _set(const ComicTranscribing('대사를 알아듣고 있어요'));
    final failure = await _awaitTranscript(path);
    if (_disposed) return;
    if (failure != null) {
      _set(ComicFailed(failure, null));
      return;
    }
    await start();
  }

  /// 전사가 끝날 때까지 기다리며 진행률을 화면에 흘린다. 실패 사유를 돌려주고,
  /// 잘 끝나면 null이다.
  ///
  /// 자막 화면과 **같은 작업**을 본다([stt.TranscriptStore.ensure]는 같은
  /// videoId에 하나만 돌린다). 그래서 편집 화면에서 이미 돌고 있으면 여기서는
  /// 그 진행률만 따라간다.
  Future<String?> _awaitTranscript(String videoPath) {
    final job = _store.ensure(videoId, videoPath);
    final done = Completer<String?>();
    void onChanged() {
      switch (job.value) {
        case stt.TranscriptRunning(:final percent):
          if (!_disposed) {
            _set(
              ComicTranscribing(
                '대사를 알아듣고 있어요',
                percent: percent == 0 ? null : percent,
              ),
            );
          }
        case stt.TranscriptReady():
          if (!done.isCompleted) done.complete(null);
        case stt.TranscriptFailed(:final reason):
          if (!done.isCompleted) done.complete(reason);
      }
    }

    job.addListener(onChanged);
    onChanged();
    return done.future.whenComplete(() => job.removeListener(onChanged));
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

  /// 화면을 열 때의 진입점. 전에 만든 만화가 있으면 그것을 먼저 보여 준다.
  ///
  /// 그림 생성이 백그라운드로 바뀌면서 "화면을 벗어난 뒤에 끝나는 것"이 정상
  /// 경로가 됐다. 그래서 열자마자 구성부터 받으면 이미 만들어 둔 만화를 못 보고
  /// 돈만 다시 쓴다. 서버 상태를 먼저 물어보고 갈래를 정한다.
  Future<void> open() async {
    ComicJobStatus status;
    try {
      status = await gateway.jobStatus(videoId);
    } catch (_) {
      // 상태를 못 물어봤다고 만들기 자체를 막을 이유는 없다.
      await start();
      return;
    }
    // 서버가 들고 있는 구성을 먼저 받아 둔다. 이게 없으면 화면에 들어올 때마다
    // 구성을 새로 받아서, 뒤로 갔다 오면 고친 대사가 사라지고 Gemini 호출료가
    // 다시 든다 — 실제로 그렇게 돌고 있었다.
    if (status.cuts != null && status.cuts!.isNotEmpty) {
      _cuts = status.cuts!;
    }
    if (status.done && status.imageUrl != null) {
      try {
        final image = await gateway.download(status.imageUrl!);
        // 구성이 함께 왔으면 완성 화면으로 간다 — 자막 띠가 얹히고 저장·공유·
        // 대사 고치기가 그대로 있다. 예전에는 언제나 ComicSaved로 갔는데, 그
        // 화면은 그림만 그려서 나갔다 오면 **대사 네 줄이 사라진 것처럼**
        // 보였다(실사용 지적). 구성을 못 받은 옛 만화만 ComicSaved로 둔다.
        _set(
          _cuts.isEmpty
              ? ComicSaved(image, status.savedAt)
              : ComicReady(_cuts, image, savedAt: status.savedAt),
        );
        return;
      } catch (_) {
        // 그림을 못 받았으면 처음부터 만들 수 있게 둔다.
      }
    }
    if (status.working) {
      _set(ComicLoadingImage(_cuts, queuePosition: status.queuePosition));
      _poll();
      return;
    }
    // 그림은 없지만 구성이 있으면 거기서 이어 간다. 구성을 다시 받지 않는다.
    if (_cuts.isNotEmpty) {
      _set(ComicScriptReady(_cuts));
      return;
    }
    await start();
  }

  /// 실패해도 _cuts를 그대로 둔다 — 사용자가 고친 것을 잃으면 처음부터 다시
  /// 고쳐야 한다.
  ///
  /// 서버에 맡기고 곧바로 돌아온다. 화면을 벗어나도 서버는 계속 그리고, 끝나면
  /// 알림이 온다 — 예전에는 이 호출이 응답을 기다리는 동안 화면을 붙잡고 있어서
  /// 사용자가 나가면 그 시간이 통째로 버려졌다.
  Future<void> makeImage() async {
    if (_cuts.isEmpty) return;
    _set(ComicLoadingImage(_cuts));
    try {
      final status = await gateway.enqueueImage(videoId, _cuts);
      if (status.done && status.imageUrl != null) {
        _set(ComicReady(_cuts, await gateway.download(status.imageUrl!)));
        return;
      }
      _set(ComicLoadingImage(_cuts, queuePosition: status.queuePosition));
      _poll();
    } catch (error) {
      _set(ComicFailed('$error', _cuts));
    }
  }

  /// 진행 상황을 따라간다. 화면이 열려 있는 동안만 돈다 — 닫히면 dispose가
  /// 멈추고, 그 뒤의 완료는 알림이 알려 준다.
  void _poll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(_pollInterval, () async {
      if (_disposed) return;
      ComicJobStatus status;
      try {
        status = await gateway.jobStatus(videoId);
      } catch (_) {
        // 한 번 실패한 것으로 만들기를 실패로 보지 않는다 — 다음 차례에 다시 본다.
        if (!_disposed) _poll();
        return;
      }
      if (_disposed) return;
      if (status.done && status.imageUrl != null) {
        try {
          _set(ComicReady(_cuts, await gateway.download(status.imageUrl!)));
        } catch (error) {
          _set(ComicFailed('$error', _cuts));
        }
        return;
      }
      if (status.failed) {
        _set(ComicFailed(status.error ?? '만화를 만들지 못했어요.', _cuts));
        return;
      }
      _set(ComicLoadingImage(_cuts, queuePosition: status.queuePosition));
      _poll();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }
}
