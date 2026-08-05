/// videoId로 찾는 자막 캐시.
///
/// **왜 필요한가**: whisper 전사는 2분 영상에 100초가 넘는다. 같은 영상을 다시
/// 열 때마다 또 기다리면 못 쓴다. 한 번 전사한 결과를 파일로 남긴다.
///
/// 실제 전사는 주입받은 [VideoTranscriber] 하나에 맡긴다. 이 클래스는 파일
/// 입출력과 작업 중복 방지만 한다 — 그래야 whisper 없이 테스트할 수 있다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'android_audio.dart';
import 'caption_line.dart';
import 'mlkit_transcriber.dart';

/// 전사가 지금 무엇을 하는 중인가. 진행률의 뜻이 단계마다 다르다.
enum TranscriptStage {
  /// 영상에서 소리를 뽑아 16kHz WAV로 바꾸는 중. 진행률을 모른다.
  audio,

  /// 대사를 알아듣는 중. 진행률이 실제 값이다.
  recognizing,
}

/// 전사 진행 상황 보고. [percent]는 0~99다.
typedef TranscribeProgress = void Function(TranscriptStage stage, int percent);

/// 영상 파일 경로를 받아 자막 줄을 돌려준다. 실패하면 던진다.
///
/// [onProgress]를 주면 진행 상황을 흘려보낸다. 주지 않아도 동작은 같다 —
/// 테스트 대역은 무시하면 된다.
typedef VideoTranscriber =
    Future<List<CaptionLine>> Function(
      String videoPath, [
      TranscribeProgress? onProgress,
    ]);

sealed class TranscriptJobState {
  const TranscriptJobState();
}

/// 돌고 있다.
///
/// **[percent]는 짐작이 아니라 실제 값이다.** 엔진이 진행 상황을 알려주지
/// 않지만 우리가 오디오를 직접 먹이므로 먹인 양을 안다(`MlKitTranscriber`).
/// 예전에는 화면이 예상 시간으로 퍼센트를 만들었는데, 예상보다 오래 걸리면
/// 95%에 붙어 멈춘 것처럼 보였고 시트를 닫았다 열면 1%부터 다시 셌다 —
/// 세는 주체가 화면이었기 때문이다. 이제 작업이 세고, 화면은 읽기만 한다.
///
/// [TranscriptStage.audio] 단계에서는 진행률을 모르므로 0이다.
class TranscriptRunning extends TranscriptJobState {
  const TranscriptRunning({
    this.stage = TranscriptStage.audio,
    this.percent = 0,
  });

  final TranscriptStage stage;
  final int percent;
}

class TranscriptReady extends TranscriptJobState {
  const TranscriptReady(this.lines);
  final List<CaptionLine> lines;
}

class TranscriptFailed extends TranscriptJobState {
  const TranscriptFailed(this.reason);
  final String reason;
}

class TranscriptStore {
  TranscriptStore({required this.transcriber, required this.root});

  final VideoTranscriber transcriber;

  /// 자막을 둘 폴더. 임시 폴더가 아니라 **영구 저장소**여야 한다 — 시스템이
  /// 정리해 가면 캐시가 매번 날아간다.
  final Future<Directory> Function() root;

  /// 도는 중인 작업. 같은 videoId로 두 번 부르면 같은 것을 돌려준다.
  ///
  /// ponytail: 앱이 살아있는 동안 계속 쌓인다. 한 번 실행에서 여는 영상 수만큼
  /// 이라 문제되지 않는다. 영상을 수백 개 넘기게 되면 LRU로 자른다.
  final _jobs = <String, ValueNotifier<TranscriptJobState>>{};

  /// 테스트가 완료를 기다릴 수 있게 마지막 작업 Future를 남긴다.
  @visibleForTesting
  Future<void>? pending;

  Future<File> _file(String videoId) async {
    final directory = await root();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$videoId.json');
  }

  /// 캐시된 자막. 없거나 읽을 수 없으면 null — 호출부는 다시 전사한다.
  Future<List<CaptionLine>?> read(String videoId) async {
    try {
      final file = await _file(videoId);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      final raw = (decoded as Map)['lines'] as List;
      return [
        for (final entry in raw)
          CaptionLine(
            startMs: (entry as Map)['startMs'] as int,
            endMs: entry['endMs'] as int,
            text: entry['text'] as String,
          ),
      ];
    } catch (error) {
      // 깨진 파일로 화면을 막지 않는다. 다시 전사하면 된다.
      debugPrint('[stt] 자막 캐시를 읽지 못했습니다($videoId): $error');
      return null;
    }
  }

  Future<void> write(String videoId, List<CaptionLine> lines) async {
    final file = await _file(videoId);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'lines': [
          for (final line in lines)
            {'startMs': line.startMs, 'endMs': line.endMs, 'text': line.text},
        ],
      }),
    );
  }

  /// 캐시가 있으면 즉시 완료 상태로, 없으면 백그라운드 전사를 시작한다.
  ValueListenable<TranscriptJobState> ensure(String videoId, String videoPath) {
    final existing = _jobs[videoId];
    if (existing != null) return existing;

    final job = ValueNotifier<TranscriptJobState>(const TranscriptRunning());
    _jobs[videoId] = job;
    pending = _run(videoId, videoPath, job);
    return job;
  }

  /// 이 영상의 전사가 지금 돌고 있는가. 화면이 "이미 돌고 있으니 기다리면
  /// 된다"를 판단하는 데 쓴다.
  bool isRunning(String videoId) => _jobs[videoId]?.value is TranscriptRunning;

  /// 캐시를 버리고 **처음부터 다시** 전사한다.
  ///
  /// [ensure]로는 다시 돌릴 수 없다 — 돌던 작업이 남아 있으면 그것을 그대로
  /// 돌려주고, 없어도 [_run]이 파일 캐시를 먼저 읽어 옛 결과가 나온다. 둘 다
  /// 캐시가 제 일을 한 것이지만, 사용자가 "다시 만들기"를 고른 순간에는
  /// 정확히 그 두 가지가 새로 만들기를 막는다.
  ///
  /// 새 [ValueNotifier]를 돌려주므로 **부르는 쪽은 듣던 것을 갈아 끼워야
  /// 한다** ([CaptionController.restart] 참조).
  ValueListenable<TranscriptJobState> restart(
    String videoId,
    String videoPath,
  ) {
    _jobs.remove(videoId);
    final job = ValueNotifier<TranscriptJobState>(const TranscriptRunning());
    _jobs[videoId] = job;
    // 파일 캐시를 지우는 것까지가 한 묶음이다. 지우기가 실패해도 전사는
    // 이어 가되, `_run`이 옛 파일을 읽지 않도록 지운 뒤에 시작한다.
    pending = clear(videoId).then((_) => _run(videoId, videoPath, job));
    return job;
  }

  /// 캐시된 자막을 버린다. [read]·[write]와 같은 층이라, 저장 방식을 바꾼
  /// 테스트 대역은 이것도 함께 갈아 끼워야 한다.
  Future<void> clear(String videoId) async {
    try {
      final file = await _file(videoId);
      if (file.existsSync()) await file.delete();
    } catch (error) {
      // 못 지워도 전사는 돈다. 새 결과가 같은 파일을 덮어쓴다.
      debugPrint('[stt] 자막 캐시를 지우지 못했습니다($videoId): $error');
    }
  }

  Future<void> _run(
    String videoId,
    String videoPath,
    ValueNotifier<TranscriptJobState> job,
  ) async {
    try {
      final cached = await read(videoId);
      if (cached != null && cached.isNotEmpty) {
        debugPrint('[stt] 자막 캐시 적중($videoId) 줄=${cached.length}');
        job.value = TranscriptReady(cached);
        return;
      }
      final fresh = await transcriber(videoPath, (stage, percent) {
        // 끝난 뒤에 늦게 도착한 보고로 상태를 되돌리지 않는다.
        if (job.value is TranscriptRunning) {
          job.value = TranscriptRunning(stage: stage, percent: percent);
        }
      });
      if (fresh.isEmpty) {
        // 빈 결과를 저장하면 캐시 적중으로 보여 영구히 재시도가 막힌다.
        _jobs.remove(videoId);
        job.value = const TranscriptFailed('대사를 알아듣지 못했어요.');
        return;
      }
      await write(videoId, fresh);
      job.value = TranscriptReady(fresh);
    } catch (error, stack) {
      // 사유를 반드시 남긴다. 상태만 바꾸면 화면에는 "못 알아들었어요" 한 줄만
      // 뜨고, 진짜 무발화인지 오디오 추출이 깨진 것인지 구분할 수 없다.
      debugPrint('[stt] 전사 실패 ${error.runtimeType}: $error');
      debugPrint(
        '[stt] 스택: ${stack.toString().split('\n').take(3).join(' | ')}',
      );
      // 실패는 캐시하지 않는다 — 다음에 다시 부르면 재시도해야 한다.
      _jobs.remove(videoId);
      job.value = TranscriptFailed('$error');
    }
  }
}

/// 앱 전체가 쓰는 하나의 저장소.
///
/// 앱은 Riverpod을 쓰지 않으므로 전역 하나로 둔다. 테스트는 이 값을 직접
/// 갈아끼운다.
TranscriptStore transcriptStore = TranscriptStore(
  transcriber: transcribeVideo,
  root: () async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}${Platform.pathSeparator}captions');
  },
);

/// 모델 내려받기 진행률(0~100). 준비 중이 아니면 null이다.
///
/// 화면이 이 값을 읽어 "자막 준비 중 42%"를 보여 준다 — 모델을 처음 받는 기기는
/// 몇 분이 걸릴 수 있어서, 표시가 없으면 멈춘 것처럼 보인다.
final ValueNotifier<int?> mlkitDownloadPercent = ValueNotifier<int?>(null);

/// 이 기기에서 마지막으로 확인한 ML Kit 상태. 화면이 안내 문구를 고르는 데 쓴다.
final ValueNotifier<MlKitReadiness?> mlkitReadiness =
    ValueNotifier<MlKitReadiness?>(null);

/// ML Kit을 쓸 수 있는 상태로 만든다 — 권한을 묻고, 필요하면 모델을 받는다.
///
/// **이 두 단계를 건너뛰면 안 된다.** 권한은 파일 입력인데도 요구되고,
/// 모델을 아직 안 받은 기기는 `needsDownload`로 온다. 둘 다 처리하지 않으면
/// 멀쩡히 쓸 수 있는 기기를 포기하게 된다.
Future<MlKitReadiness> prepareMlKit(MlKitTranscriber mlkit) async {
  var state = await mlkit.readiness();

  if (state == MlKitReadiness.needsPermission) {
    debugPrint('[stt] 마이크 권한을 요청한다 — 파일 입력이어도 ML Kit이 요구한다');
    if (await mlkit.requestMicrophone()) state = await mlkit.readiness();
  }

  if (state == MlKitReadiness.needsDownload) {
    debugPrint('[stt] ML Kit 모델을 내려받는다');
    mlkitDownloadPercent.value = 0;
    try {
      state = await mlkit.ensure(
        onProgress: (percent) => mlkitDownloadPercent.value = percent,
      );
    } finally {
      mlkitDownloadPercent.value = null;
    }
    debugPrint('[stt] 내려받기 끝 — 상태=$state');
  }

  mlkitReadiness.value = state;
  if (state != MlKitReadiness.ready) {
    debugPrint('[stt] ML Kit을 쓸 수 없다($state)');
  }
  return state;
}

/// 영상에서 16kHz 모노 WAV를 뽑아 전사한다. WAV는 쓰고 지운다.
///
/// **폴백이 없다.** 예전에는 whisper가 뒤를 받쳤지만 지웠다 — 같은 영상에서
/// ML Kit이 CER 23.3% 대 35.0%로 앞섰고, 2분짜리에서 whisper는 64초 이후
/// 무너졌으며, 속도도 18초 대 235초였다. 181MiB 모델 에셋도 함께 없앴다.
///
/// 그래서 [prepareMlKit]이 실패하면 자막이 없다. 화면이 이유를 알려 줘야 한다
/// (`CaptionController.message` 참조).
Future<List<CaptionLine>> transcribeVideo(
  String videoPath, [
  TranscribeProgress? onProgress,
]) async {
  onProgress?.call(TranscriptStage.audio, 0);
  final temporary = await getTemporaryDirectory();
  final directory = Directory(
    '${temporary.path}${Platform.pathSeparator}stt',
  );
  await directory.create(recursive: true);
  final wavPath = '${directory.path}${Platform.pathSeparator}audio_16k.wav';

  await AndroidAudioExtractor().toPcmWav16k(videoPath, wavPath);
  try {
    final mlkit = MlKitTranscriber();
    if (await prepareMlKit(mlkit) != MlKitReadiness.ready) return const [];

    final lines = await mlkit.transcribe(
      wavPath,
      onProgress: onProgress == null
          ? null
          : (percent) => onProgress(TranscriptStage.recognizing, percent),
    );
    debugPrint('[stt] 엔진=ML Kit basic, ${lines.length}줄');
    // 시각은 낱말이 처음 인식된 시점으로 역산한 근사치다. 싱크가 밀리는지
    // 눈으로 판단할 수 있게 앞 몇 줄을 찍는다.
    for (final line in lines.take(5)) {
      debugPrint('[stt]   ${line.startMs}~${line.endMs}ms "${line.text}"');
    }
    return lines;
  } finally {
    final wav = File(wavPath);
    if (wav.existsSync()) await wav.delete();
  }
}
