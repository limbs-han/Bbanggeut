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

import 'package:flutter/foundation.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import 'caption_line.dart';
import 'pcm_wav.dart';
import 'speech_analysis.dart';

class WhisperTranscriber {
  WhisperTranscriber({
    required this.modelPath,
    this.localeTag = 'ko',
    this.threads = 6,
    Whisper? whisper,
  }) : _whisper = whisper ?? const Whisper(model: WhisperModel.small);

  /// GGML 모델 파일의 절대 경로. `resolveWhisperModel()`이 확보해 준다
  /// (whisper_model.dart 참조 — 에셋에서 복사하거나 dart-define 경로를 쓴다).
  final String modelPath;

  /// whisper 언어 코드 — 지역 접미사 없이 'ko'.
  final String localeTag;

  /// 추론 스레드 수. 갤럭시 S24에서 같은 영상으로 실측했다 — 4개 68~73초,
  /// 6개 56초로 약 18% 빠르다. **알아듣는 양은 스레드와 무관했다.**
  ///
  /// 값을 바꿀 때는 **같은 영상으로 시간과 글자 수를 함께** 재라. 시간만 보면
  /// 개선으로 착각한다 — 한 번 그렇게 잘못 짚었다. 글자가 줄어든 것을 스레드
  /// 탓으로 봤는데 진짜 원인은 발화 구간 이어붙이기였다(_hasSpeech 주석 참조).
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

    // 말소리가 아예 없으면 whisper를 돌리지 않는다. 120초 영상에 90초 넘게 걸리는
    // 일을 헛되게 하지 않는다.
    if (!await _hasSpeech(wavPath)) {
      debugPrint('[stt] 말소리가 없어 전사를 건너뜁니다');
      return const [];
    }

    final stopwatch = Stopwatch()..start();
    final WhisperTranscribeResponse response;
    try {
      response = await _whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          // 원본 전체를 넘긴다. 발화 구간만 잘라 이어붙이면 문맥이 끊겨 인식률이
          // 무너진다 (아래 실측 참조).
          audio: wavPath,
          language: localeTag,
          threads: threads,
          // 구간 시각이 필요하다 — 자막을 시각에 맞춰 띄워야 한다.
          isNoTimestamps: false,
          isTranslate: false,
          // 패키지 VAD는 끈다 — 우리가 말소리 유무만 미리 보고 통과시킨다.
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
    }
    stopwatch.stop();

    final lines = _toLines(response);
    debugPrint(
      '[stt] whisper ${stopwatch.elapsed.inSeconds}초 줄=${lines.length} '
      '글자=${lines.fold(0, (n, l) => n + l.text.length)}',
    );
    return lines;
  }

  /// 말소리가 조금이라도 있는지 본다. 없으면 whisper를 돌릴 이유가 없다.
  ///
  /// **발화 구간만 잘라 이어붙이지는 않는다.** 갤럭시 S24에서 같은 영상으로
  /// 실측했다:
  ///
  ///   이어붙임(발화 37s)  75초 → 원문 65자,  구간 2개
  ///   원본 그대로(120s)   93초 → 원문 143자, 구간 5개
  ///
  /// 시간은 24% 늘지만 알아듣는 양이 2.2배다. whisper는 30초 창 단위로 처리하고
  /// 침묵은 토큰이 거의 안 나와 빠르게 지나간다 — 미리 걷어내도 아끼는 시간이
  /// 얼마 없는데, 이음새마다 파형이 끊기고 문맥이 엉켜 인식이 무너진다.
  Future<bool> _hasSpeech(String wavPath) async {
    try {
      final wav = PcmWav.parse(await File(wavPath).readAsBytes());
      return detectSpeechRegions(wav).isNotEmpty;
    } catch (error) {
      // 판정에 실패하면 통과시킨다 — 여기서 막으면 멀쩡한 영상의 자막을 잃는다.
      debugPrint('[stt] 말소리 판정 실패, 그대로 전사합니다: $error');
      return true;
    }
  }

  /// whisper 응답을 자막 줄로 옮긴다.
  ///
  /// 구간 목록이 비어 있으면(모델이 시각을 안 준 경우) 빈 목록을 돌려준다.
  /// 시각 없는 자막은 띄울 자리가 없어 쓸 수 없다.
  List<CaptionLine> _toLines(WhisperTranscribeResponse response) {
    final raw = response.segments;
    if (raw == null || raw.isEmpty) {
      debugPrint('[stt] whisper가 구간 시각을 주지 않았습니다: "${response.text.trim()}"');
      return const [];
    }
    final out = <CaptionLine>[];
    for (final segment in raw) {
      final text = segment.text.trim();
      if (text.isEmpty) continue;
      final start = segment.fromTs;
      final end = segment.toTs;
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
