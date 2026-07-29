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
import 'whisper_model.dart';
import 'whisper_transcriber.dart';

/// 영상 파일 경로를 받아 자막 줄을 돌려준다. 실패하면 던진다.
typedef VideoTranscriber = Future<List<CaptionLine>> Function(String videoPath);

sealed class TranscriptJobState {
  const TranscriptJobState();
}

/// 돌고 있다. 진행률은 없다 — whisper가 중간 상황을 알려주지 않는다.
/// 화면은 자기가 아는 영상 길이로 예상 시간을 계산해 보여준다.
class TranscriptRunning extends TranscriptJobState {
  const TranscriptRunning();
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
      final fresh = await transcriber(videoPath);
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

/// 영상에서 16kHz 모노 WAV를 뽑아 whisper에 넘긴다. WAV는 쓰고 지운다.
Future<List<CaptionLine>> transcribeVideo(String videoPath) async {
  final temporary = await getTemporaryDirectory();
  final directory = Directory(
    '${temporary.path}${Platform.pathSeparator}stt',
  );
  await directory.create(recursive: true);
  final wavPath = '${directory.path}${Platform.pathSeparator}audio_16k.wav';

  // 모델을 먼저 확보한다 — 에셋에서 복사하거나 dart-define 경로를 쓴다.
  final modelPath = await resolveWhisperModel();
  await AndroidAudioExtractor().toPcmWav16k(videoPath, wavPath);
  try {
    return await WhisperTranscriber(modelPath: modelPath).transcribe(wavPath);
  } finally {
    final wav = File(wavPath);
    if (wav.existsSync()) await wav.delete();
  }
}
