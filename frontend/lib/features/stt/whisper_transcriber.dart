/// 앱에 담은 whisper.cpp 모델로 영상의 대사를 전사한다.
///
/// **왜 whisper인가**: 안드로이드 온디바이스 인식기(`createOnDeviceSpeechRecognizer`
/// + `EXTRA_AUDIO_SOURCE`)가 파일 입력에서 비정상 종료한다. 갤럭시 S24 실측에서
/// 전제 조건을 모두 갖춘 상태(Android 16, 한국어 모델 설치, 유효한 16kHz 모노
/// PCM, 1.8~2.3초 구간)로도 12구간 전부 빈 결과였고, 결과 번들에 키 자체가
/// 없었다. 에러도 아니어서 우리 코드로 우회할 방법이 없다.
///
/// **모델**: `SungBeom/whisper-small-ko`를 q5_0으로 양자화한 것(465MB → 167MB).
/// 정답을 아는 TTS 클립에서 CER 0.0%였다. 한국어 미세조정이 모델 크기보다
/// 중요하다 — 미세조정한 small이 원본 large-v3보다 정확했다(6.5% 대 11.1%).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import 'caption_line.dart';
import 'pcm_wav.dart';
import 'speech_analysis.dart';

class WhisperTranscriber {
  WhisperTranscriber({
    required this.modelPath,
    this.localeTag = 'ko',
    this.threads = 4,
    Whisper? whisper,
  }) : _whisper = whisper ?? const Whisper(model: WhisperModel.small);

  /// GGML 모델 파일의 절대 경로. `resolveWhisperModel()`이 확보해 준다
  /// (whisper_model.dart 참조 — 에셋에서 복사하거나 dart-define 경로를 쓴다).
  final String modelPath;

  /// whisper 언어 코드 — 지역 접미사 없이 'ko'.
  final String localeTag;

  /// 추론 스레드 수.
  ///
  /// **올리지 말 것.** 갤럭시 S24에서 같은 영상으로 실측했다:
  ///
  ///   4개 → 73초, 124자
  ///   6개 → 56초,  63자   ← 23% 빨라지지만 대사를 절반 놓친다
  ///
  /// 속도보다 알아듣는 양이 중요하다. 값을 바꾸면 **같은 영상으로 글자 수까지**
  /// 다시 재야 한다 — 시간만 보면 개선으로 착각한다.
  final int threads;

  final Whisper _whisper;

  /// 실패하면 던진다 — 호출부가 자막 없이 진행한다.
  ///
  /// 실패 사유를 여기서 직접 로그에 남긴다. 그러지 않으면 "조용히 무발화로
  /// 떨어짐"과 구분할 수 없다.
  Future<List<CaptionLine>> transcribe(String wavPath) async {
    final audio = File(wavPath);
    final model = File(modelPath);
    final audioSize = await audio.exists() ? await audio.length() : -1;
    final modelSize = await model.exists() ? await model.length() : -1;
    debugPrint(
      '[stt] whisper 시작 오디오=$wavPath($audioSize바이트) '
      '모델=$modelPath($modelSize바이트)',
    );

    if (modelSize <= 0) {
      debugPrint('[stt] whisper 중단: 모델 파일을 읽을 수 없음');
      throw StateError('whisper 모델 파일이 없습니다: $modelPath');
    }

    // 침묵을 빼고 발화 구간만 이어붙여 넘긴다 — 처리량이 발화 비율만큼 줄고,
    // 결과 시각을 원본 시간축으로 되돌릴 수 있게 매핑을 함께 만든다.
    final condensed = await _condense(wavPath);
    final target = condensed?.path ?? wavPath;

    final stopwatch = Stopwatch()..start();
    final WhisperTranscribeResponse response;
    try {
      response = await _whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: target,
          language: localeTag,
          threads: threads,
          // 구간 시각이 필요하다 — 자막을 시각에 맞춰 띄워야 한다.
          isNoTimestamps: false,
          isTranslate: false,
          // 우리가 이미 발화 구간을 골랐으므로 패키지 VAD는 끈다.
          vadMode: WhisperVadMode.disabled,
          // ⚠ disabled일 때 패키지가 vadModelPath를 null로 남기는데
          // (bundled_vad_model_resolver.dart:19-20) 네이티브는 그 필드를
          // 문자열로 읽어 "type must be string, but is null"로 죽는다.
          // 빈 문자열이면 null이 아니면서 VAD도 켜지지 않는다.
          vadModelPath: '',
        ),
        modelPath: modelPath,
      );
    } catch (error, stack) {
      debugPrint('[stt] whisper 실패 ${error.runtimeType}: $error');
      debugPrint(
        '[stt] whisper 스택: ${stack.toString().split('\n').take(4).join(' | ')}',
      );
      rethrow;
    } finally {
      if (condensed != null && condensed.file.existsSync()) {
        await condensed.file.delete();
      }
    }
    stopwatch.stop();

    final lines = _toLines(response, condensed);
    debugPrint(
      '[stt] whisper ${stopwatch.elapsed.inSeconds}초 줄=${lines.length} '
      '글자=${lines.fold(0, (n, l) => n + l.text.length)}'
      '${condensed == null ? "" : " (발화만 ${condensed.speechSeconds}s/${condensed.totalSeconds}s)"}',
    );
    return lines;
  }

  /// 발화 구간만 이어붙인 WAV를 만든다. 실패하면 null — 원본으로 진행한다.
  ///
  /// 왜 필요한가: 120초 클립 전체를 넘기면 갤럭시 S24에서 168초가 걸렸다.
  /// 침묵을 빼면 109초로 줄었다. 잘라 붙이면 결과 시각이 원본과 달라지므로
  /// 되돌릴 매핑을 함께 들고 나온다.
  Future<_Condensed?> _condense(String wavPath) async {
    try {
      final wav = PcmWav.parse(await File(wavPath).readAsBytes());
      final regions = detectSpeechRegions(wav);
      if (regions.isEmpty) return null;

      final pieces = <PcmWav>[];
      final spans = <_Span>[];
      var offset = Duration.zero;
      for (final region in regions) {
        // 경계에서 음절이 잘리면 인식이 무너진다. 앞뒤로 조금 넉넉히 잡는다.
        final from = region.start - _pad < Duration.zero
            ? Duration.zero
            : region.start - _pad;
        final to = region.end + _pad > wav.duration
            ? wav.duration
            : region.end + _pad;
        final piece = sliceWav(wav, from, to);
        if (piece.frameCount == 0) continue;
        pieces.add(piece);
        spans.add(_Span(condensedStart: offset, originalStart: from));
        offset += piece.duration;
      }
      if (pieces.isEmpty) return null;

      final merged = Int16List(pieces.fold(0, (n, p) => n + p.samples.length));
      var at = 0;
      for (final piece in pieces) {
        merged.setRange(at, at + piece.samples.length, piece.samples);
        at += piece.samples.length;
      }
      final condensedWav = PcmWav(
        samples: merged,
        sampleRate: wav.sampleRate,
        channels: 1,
      );

      final out = File('$wavPath.speech.wav');
      await out.writeAsBytes(encodeWav(condensedWav));
      return _Condensed(
        file: out,
        spans: spans,
        speechSeconds: condensedWav.duration.inSeconds,
        totalSeconds: wav.duration.inSeconds,
      );
    } catch (error) {
      debugPrint('[stt] 발화 구간 추출 실패, 원본으로 진행: $error');
      return null;
    }
  }

  /// whisper 응답을 자막 줄로 옮긴다.
  ///
  /// 구간 목록이 비어 있으면(모델이 시각을 안 준 경우) 빈 목록을 돌려준다.
  /// 시각 없는 자막은 띄울 자리가 없어 쓸 수 없다 — 4컷 만화와 다른 점이다.
  List<CaptionLine> _toLines(
    WhisperTranscribeResponse response,
    _Condensed? condensed,
  ) {
    final raw = response.segments;
    if (raw == null || raw.isEmpty) {
      debugPrint('[stt] whisper가 구간 시각을 주지 않았습니다: "${response.text.trim()}"');
      return const [];
    }
    final out = <CaptionLine>[];
    for (final segment in raw) {
      final text = segment.text.trim();
      if (text.isEmpty) continue;
      // 발화만 이어붙였다면 시각을 원본 시간축으로 되돌린다.
      final start = condensed?.toOriginal(segment.fromTs) ?? segment.fromTs;
      final end = condensed?.toOriginal(segment.toTs) ?? segment.toTs;
      if (end <= start) continue;
      out.add(
        CaptionLine(
          startMs: start.inMilliseconds,
          endMs: end.inMilliseconds,
          text: text,
        ),
      );
    }
    // 쪼개기 전 원문을 재 둔다. 쪼개기가 글자를 버리는지, whisper가 애초에 덜
    // 알아들었는지 이 줄 하나로 갈린다 — 없으면 구분할 수 없다.
    debugPrint(
      '[stt] whisper 원문 구간=${out.length} 글자=${out.fold(0, (n, l) => n + l.text.length)}',
    );

    // whisper는 문장 단위로 길게 끊어 준다. 자막으로 쓰려면 쪼개야 한다.
    return splitIntoLines(out);
  }
}

/// 발화 구간 경계에서 음절이 잘리지 않도록 앞뒤로 두는 여유.
const _pad = Duration(milliseconds: 200);

/// 이어붙인 오디오의 한 조각이 원본에서 어디였는지.
class _Span {
  const _Span({required this.condensedStart, required this.originalStart});
  final Duration condensedStart;
  final Duration originalStart;
}

/// 발화만 모은 WAV와 원본 시간축 복원 정보.
class _Condensed {
  const _Condensed({
    required this.file,
    required this.spans,
    required this.speechSeconds,
    required this.totalSeconds,
  });

  final File file;
  final List<_Span> spans;
  final int speechSeconds;
  final int totalSeconds;

  String get path => file.path;

  /// 이어붙인 시각을 원본 시각으로 되돌린다.
  ///
  /// 해당 시각이 속한 조각을 찾아, 그 조각 안에서의 상대 위치를 원본 시작점에
  /// 더한다. 조각을 못 찾으면(경계 반올림 등) 첫 조각 기준으로 계산한다.
  Duration toOriginal(Duration condensedAt) {
    if (spans.isEmpty) return condensedAt;
    var chosen = spans.first;
    for (final span in spans) {
      if (span.condensedStart <= condensedAt) {
        chosen = span;
      } else {
        break;
      }
    }
    return chosen.originalStart + (condensedAt - chosen.condensedStart);
  }
}
