/// features/stt 검증 — 순수 Dart 로직 전부.
///
/// whisper 자체(네이티브 추론)와 MediaCodec 디코더는 여기서 돌리지 않는다.
/// 검증 대상은 그 위아래의 우리 코드다: 발화 구간 검출, 리샘플·슬라이스,
/// 자막 시각 판정, 내보내기용 시각 옮기기, 캐시.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/android_audio.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/pcm_wav.dart';
import 'package:william_james_app/features/stt/speech_analysis.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

const _window = Duration(milliseconds: 100);

/// 창별 진폭으로 사인파 WAV를 만든다. 사인파는 하모닉이 하나라 스펙트럼
/// 평탄도가 낮다 — 발화의 성질을 흉내낸 것.
Uint8List toneWav(
  List<double> amplitudes, {
  double frequency = 220,
  int sampleRate = 16000,
  int channels = 1,
  Duration window = _window,
}) => _wav(
  amplitudes,
  sampleRate: sampleRate,
  channels: channels,
  window: window,
  sample: (frameIndex, amplitude) =>
      amplitude * math.sin(2 * math.pi * frequency * frameIndex / sampleRate),
);

/// 결정적 LCG 백색 잡음. 에너지가 전 대역에 퍼져 평탄도가 높다.
Uint8List noiseWav(
  List<double> amplitudes, {
  int sampleRate = 16000,
  Duration window = _window,
}) {
  var seed = 12345;
  return _wav(
    amplitudes,
    sampleRate: sampleRate,
    channels: 1,
    window: window,
    sample: (_, amplitude) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return amplitude * ((seed / 0x3FFFFFFF) - 1);
    },
  );
}

Uint8List _wav(
  List<double> amplitudes, {
  required int sampleRate,
  required int channels,
  required Duration window,
  required double Function(int frameIndex, double amplitude) sample,
}) {
  final framesPerWindow = sampleRate * window.inMilliseconds ~/ 1000;
  final frames = framesPerWindow * amplitudes.length;
  final samples = Int16List(frames * channels);
  var frameIndex = 0;
  for (final amplitude in amplitudes) {
    for (var f = 0; f < framesPerWindow; f++, frameIndex++) {
      final value = (sample(frameIndex, amplitude) * 32767).round().clamp(
        -32768,
        32767,
      );
      for (var c = 0; c < channels; c++) {
        samples[frameIndex * channels + c] = value;
      }
    }
  }
  return encodeWav(
    PcmWav(samples: samples, sampleRate: sampleRate, channels: channels),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('스펙트럼 평탄도', () {
    List<double> monoSamples(Uint8List wav) {
      final parsed = PcmWav.parse(wav);
      return [for (final s in parsed.samples) s / 32768.0];
    }

    test('사인파는 낮고 백색 잡음은 높다', () {
      final tone = spectralFlatness(monoSamples(toneWav(const [0.6])));
      final noise = spectralFlatness(monoSamples(noiseWav(const [0.6])));
      expect(tone, lessThan(noise));
    });

    test('무음은 판정하지 않고 1(평탄)로 둔다 — 발화로 잡히지 않는다', () {
      // 기하평균/산술평균 비율이라 정확히 1.0이 아니라 1에 수렴한다.
      expect(spectralFlatness(monoSamples(toneWav(const [0]))), closeTo(1, 1e-9));
    });
  });

  group('발화 구간 검출', () {
    test('무음 속 사인파 구간을 시각과 함께 찾아낸다', () {
      // 0.5초 무음 → 1.0초 발화 → 0.5초 무음
      final wav = PcmWav.parse(
        toneWav(const [0, 0, 0, 0, 0, 0.7, 0.7, 0.7, 0.7, 0.7, 0, 0, 0, 0, 0]),
      );
      final regions = detectSpeechRegions(wav);

      expect(regions, isNotEmpty);
      expect(regions.first.start.inMilliseconds, greaterThanOrEqualTo(300));
      expect(regions.first.end.inMilliseconds, lessThanOrEqualTo(1700));
    });

    test('큰 잡음만 있으면 발화로 잡지 않는다 — RMS만 보면 놓치는 오탐', () {
      final wav = PcmWav.parse(
        noiseWav(const [0, 0, 0.8, 0.8, 0.8, 0.8, 0.8, 0, 0]),
      );
      expect(detectSpeechRegions(wav), isEmpty);
    });

    test('발화 비율을 계산한다', () {
      final wav = PcmWav.parse(
        toneWav(const [0, 0, 0.7, 0.7, 0.7, 0.7, 0.7, 0, 0, 0]),
      );
      final ratio = speechRatio(wav, detectSpeechRegions(wav));
      expect(ratio, greaterThan(0.2));
      expect(ratio, lessThan(1.0));
    });
  });

  group('리샘플·슬라이스', () {
    test('48kHz 스테레오를 16kHz 모노로 접는다', () {
      final source = PcmWav.parse(
        toneWav(const [0.5, 0.5], sampleRate: 48000, channels: 2),
      );
      final converted = resample(source, sttSampleRate);

      expect(converted.sampleRate, sttSampleRate);
      expect(converted.channels, 1);
      expect(
        converted.duration.inMilliseconds,
        closeTo(source.duration.inMilliseconds, 20),
      );
    });

    test('구간을 잘라 WAV로 다시 쓰면 길이가 유지된다', () {
      final source = PcmWav.parse(toneWav(List.filled(20, 0.5)));
      final slice = sliceWav(
        source,
        const Duration(milliseconds: 400),
        const Duration(milliseconds: 900),
      );
      final round = PcmWav.parse(encodeWav(slice));

      expect(round.duration.inMilliseconds, closeTo(500, 5));
      expect(round.sampleRate, source.sampleRate);
    });

    test('원시 PCM은 헤더 없이 샘플만 담는다', () {
      final source = PcmWav.parse(toneWav(const [0.5]));
      expect(encodePcm16(source).length, source.samples.length * 2);
    });
  });

  group('captionAt', () {
    final lines = [
      CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
      CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
    ];

    test('구간 안이면 그 글', () {
      expect(captionAt(lines, 1000), '그거 만지지 마');
      expect(captionAt(lines, 2999), '그거 만지지 마');
      expect(captionAt(lines, 6000), '안 만졌는데요');
    });

    test('시작 포함 끝 제외 — 붙은 두 줄이 경계에서 겹치지 않는다', () {
      expect(captionAt(lines, 3000), isNull);
    });

    test('구간 사이 침묵이면 아무것도 없다', () {
      expect(captionAt(lines, 4000), isNull);
    });

    test('줄이 없으면 아무것도 없다', () {
      expect(captionAt(const [], 0), isNull);
    });
  });

  group('splitIntoLines', () {
    test('짧은 줄은 그대로 둔다', () {
      final lines = [
        CaptionLine(startMs: 0, endMs: 2000, text: '안 만졌는데요'),
      ];
      final split = splitIntoLines(lines);
      expect(split, hasLength(1));
      expect(split.single.text, '안 만졌는데요');
      expect(split.single.startMs, 0);
      expect(split.single.endMs, 2000);
    });

    test('구두점이 없으면 낱말 경계에서 글자 수로 나눈다', () {
      final split = splitIntoLines([
        CaptionLine(
          startMs: 0,
          endMs: 4000,
          text: '엄마가 아이에게 말했어요 그거 만지지 마 안 만졌는데요',
        ),
      ]);

      // 한도(20자)를 넘지 않게 낱말 단위로 담는다. 낱말 중간을 자르지 않는다.
      expect(split.map((l) => l.text), [
        '엄마가 아이에게 말했어요 그거 만지지',
        '마 안 만졌는데요',
      ]);
    });

    test('구두점에서도 나눈다', () {
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 3000, text: '그거 만지지 마. 왜? 안 만졌어!'),
      ]);

      expect(split.map((l) => l.text), ['그거 만지지 마.', '왜?', '안 만졌어!']);
    });

    test('한국어 어미로는 끊지 않는다 — 낱말 안의 글자와 구분할 수 없다', () {
      // 종결어미 목록(요·다·죠·까·네)으로 나눠 봤지만 "만지지"의 지처럼 낱말
      // 안의 글자를 문장 끝으로 착각해 대사가 부서졌다. 구두점만 본다.
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 2000, text: '그거 만지지 마 다 먹었어'),
      ]);

      expect(split, hasLength(1));
      expect(split.single.text, '그거 만지지 마 다 먹었어');
    });

    test('구두점으로 나눈 뒤에도 길면 글자 수로 더 나눈다', () {
      final split = splitIntoLines([
        CaptionLine(
          startMs: 0,
          endMs: 4000,
          text: '어제 우리 가족이 함께 놀이터에 가서 정말 재미있게 놀았어. 좋았다.',
        ),
      ]);

      expect(split.length, greaterThan(2), reason: '구두점 2개 + 글자 수 나눔');
      for (final line in split) {
        expect(
          line.text.length,
          lessThanOrEqualTo(captionMaxChars),
          reason: '한 줄이 한도를 넘으면 화면에 안 들어간다: "${line.text}"',
        );
      }
      // 문장 경계를 넘는 줄이 없어야 한다 — 어느 줄도 두 문장에 걸치지 않는다.
      expect(
        split.any((l) => l.text.endsWith('놀았어.')),
        isTrue,
        reason: '첫 문장이 그 자리에서 끝나야 한다',
      );
      expect(split.last.text, '좋았다.');
    });

    test('쪼갠 줄들이 원래 구간을 빈틈 없이 채운다', () {
      final split = splitIntoLines([
        CaptionLine(
          startMs: 1000,
          endMs: 5000,
          text: '엄마가 아이에게 말했어요 그거 만지지 마 안 만졌는데요',
        ),
      ]);

      expect(split.first.startMs, 1000);
      expect(split.last.endMs, 5000);
      for (var i = 1; i < split.length; i++) {
        expect(split[i].startMs, split[i - 1].endMs, reason: '구간 사이가 벌어졌다');
      }
    });

    test('구간이 아주 짧아도 모든 줄이 길이를 갖는다 — 0ms는 화면에 못 뜬다', () {
      // 24자를 20자 한도로 나누면 2조각인데 구간이 3ms뿐이다. 비율대로 주면
      // 앞 조각이 3ms를 다 먹고 뒤 조각이 0ms가 된다.
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 3, text: '가나다라마바사아자차카타파하가나다라마바사아자차'),
      ]);

      for (final line in split) {
        expect(
          line.endMs,
          greaterThan(line.startMs),
          reason: '길이가 0인 줄: "${line.text}"',
        );
      }
      expect(split.last.endMs, 3, reason: '원래 끝 시각을 넘지 않아야 한다');
    });

    test('구간이 조각 수보다 짧으면 쪼개지 않는다', () {
      const long = '가나다라마바사아자차카타파하가나다라마바사아자차';
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 1, text: long),
      ]);

      expect(split, hasLength(1));
      expect(split.single.text, long);
    });

    test('낱말 하나가 한도를 넘으면 통째로 자르되 글자를 버리지 않는다', () {
      const glued = '가나다라마바사아자차카타파하가나다라마바사아자차카타파하가나다라마바';
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 2000, text: glued),
      ]);

      expect(split.length, greaterThan(1));
      for (final line in split) {
        expect(line.text.length, lessThanOrEqualTo(captionMaxChars));
      }
      expect(split.map((l) => l.text).join(), glued);
    });

    test('나누어도 글자가 사라지지 않는다 — 공백만 경계에서 줄어든다', () {
      const text = '엄마가 아이에게 말했어요 그거 만지지 마 안 만졌는데요';
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 4000, text: text),
      ]);

      final before = text.replaceAll(' ', '');
      final after = split.map((l) => l.text).join().replaceAll(' ', '');
      expect(after, before, reason: '공백을 뺀 글자는 그대로여야 한다');
    });

    test('한도를 바꿀 수 있다', () {
      final split = splitIntoLines([
        CaptionLine(startMs: 0, endMs: 2000, text: '엄마가 아이에게 말했어요'),
      ], maxChars: 6);

      for (final line in split) {
        expect(line.text.length, lessThanOrEqualTo(6));
      }
    });
  });

  group('captionsForExport', () {
    List<CaptionLine> lines() => [
      CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
      CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
      CaptionLine(startMs: 20000, endMs: 22000, text: '안 만졌다면서'),
    ];

    test('자른 구간 밖의 줄을 버린다', () {
      final exported = captionsForExport(lines(), startMs: 4000, endMs: 10000);
      expect(exported, hasLength(1));
      expect(exported.single['text'], '안 만졌는데요');
    });

    test('시각을 자른 시작점 기준으로 옮긴다', () {
      final exported = captionsForExport(lines(), startMs: 4000, endMs: 10000);
      // 원본 5000~7000이 클립 기준 1000~3000이 된다.
      expect(exported.single['startMs'], 1000);
      expect(exported.single['endMs'], 3000);
    });

    test('경계에 걸친 줄은 자른 구간 안으로 잘라 남긴다', () {
      final exported = captionsForExport(
        [CaptionLine(startMs: 3000, endMs: 9000, text: '걸친 줄')],
        startMs: 5000,
        endMs: 7000,
      );
      expect(exported.single['startMs'], 0);
      expect(exported.single['endMs'], 2000);
    });

    test('빈 글자는 내보내지 않는다', () {
      final exported = captionsForExport(
        [CaptionLine(startMs: 0, endMs: 1000, text: '   ')],
        startMs: 0,
        endMs: 1000,
      );
      expect(exported, isEmpty);
    });

    test('endMs가 0이면 자르기가 없는 것으로 보고 전부 남긴다', () {
      final exported = captionsForExport(lines(), startMs: 0, endMs: 0);
      expect(exported, hasLength(3));
      expect(exported.first['startMs'], 1000);
    });
  });

  group('AndroidAudioExtractor', () {
    const channel = MethodChannel(sttMediaChannel);
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('stt-extract-');
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (temporary.existsSync()) await temporary.delete(recursive: true);
    });

    void answerWith(Uint8List? nativeWav) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final output = (call.arguments as Map)['output'] as String;
            if (nativeWav == null) return null;
            await File(output).writeAsBytes(nativeWav);
            return output;
          });
    }

    test('네이티브가 준 원본 샘플레이트 WAV를 16kHz 모노로 바꿔 저장한다', () async {
      answerWith(toneWav(const [0.5, 0.5], sampleRate: 48000, channels: 2));
      final out = '${temporary.path}${Platform.pathSeparator}audio.wav';

      await AndroidAudioExtractor(channel: channel).toPcmWav16k('/in.mp4', out);

      final saved = PcmWav.parse(await File(out).readAsBytes());
      expect(saved.sampleRate, sttSampleRate);
      expect(saved.channels, 1);
    });

    test('중간 WAV는 남기지 않는다', () async {
      answerWith(toneWav(const [0.5]));
      final out = '${temporary.path}${Platform.pathSeparator}audio.wav';

      await AndroidAudioExtractor(channel: channel).toPcmWav16k('/in.mp4', out);

      expect(File('$out.native.wav').existsSync(), isFalse);
    });

    test('네이티브가 경로를 안 주면 던진다', () async {
      answerWith(null);
      await expectLater(
        AndroidAudioExtractor(channel: channel).toPcmWav16k(
          '/in.mp4',
          '${temporary.path}${Platform.pathSeparator}audio.wav',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('오디오 트랙이 비면 던진다', () async {
      answerWith(toneWav(const []));
      await expectLater(
        AndroidAudioExtractor(channel: channel).toPcmWav16k(
          '/in.mp4',
          '${temporary.path}${Platform.pathSeparator}audio.wav',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('TranscriptStore', () {
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('stt-store-');
    });

    tearDown(() async {
      if (temporary.existsSync()) await temporary.delete(recursive: true);
    });

    TranscriptStore store(VideoTranscriber transcriber) => TranscriptStore(
      transcriber: transcriber,
      root: () async => temporary,
    );

    List<CaptionLine> lines() => [
      CaptionLine(startMs: 500, endMs: 2300, text: '그거 만지지 마'),
      CaptionLine(startMs: 4000, endMs: 6000, text: '안 만졌는데요'),
    ];

    test('쓴 것을 그대로 읽는다', () async {
      final subject = store((_) async => const []);
      await subject.write('v1', lines());

      final read = await subject.read('v1');
      expect(read, hasLength(2));
      expect(read![0].startMs, 500);
      expect(read[0].endMs, 2300);
      expect(read[0].text, '그거 만지지 마');
    });

    test('캐시가 없는 videoId는 null을 돌려준다', () async {
      expect(await store((_) async => const []).read('없는영상'), isNull);
    });

    test('캐시가 있으면 전사를 다시 돌리지 않는다', () async {
      var calls = 0;
      final subject = store((_) async {
        calls++;
        return lines();
      });
      await subject.write('v1', lines());

      final job = subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;

      expect(calls, 0);
      expect(job.value, isA<TranscriptReady>());
      expect((job.value as TranscriptReady).lines, hasLength(2));
    });

    test('캐시가 없으면 한 번 전사하고 저장한다', () async {
      var calls = 0;
      final subject = store((_) async {
        calls++;
        return lines();
      });

      final job = subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;

      expect(calls, 1);
      expect(job.value, isA<TranscriptReady>());
      expect(await subject.read('v1'), hasLength(2));
    });

    test('같은 videoId로 두 번 불러도 전사는 한 번만 돈다', () async {
      var calls = 0;
      final subject = store((_) async {
        calls++;
        return lines();
      });

      final first = subject.ensure('v1', '/video/v1.mp4');
      final second = subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;

      expect(calls, 1);
      expect(second, same(first));
    });

    test('전사가 던지면 실패 상태가 되고 파일을 남기지 않는다', () async {
      final subject = store((_) async => throw StateError('모델 없음'));

      final job = subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;

      expect(job.value, isA<TranscriptFailed>());
      expect(await subject.read('v1'), isNull);
    });

    test('실패한 뒤 다시 부르면 재시도한다', () async {
      var calls = 0;
      final subject = store((_) async {
        calls++;
        if (calls == 1) throw StateError('첫 번째는 실패');
        return lines();
      });

      subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;
      subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;

      expect(calls, 2);
      expect(await subject.read('v1'), hasLength(2));
    });

    test('전사 결과가 비면 실패로 본다 — 빈 캐시를 남기면 재시도가 막힌다', () async {
      final subject = store((_) async => const []);

      final job = subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;

      expect(job.value, isA<TranscriptFailed>());
      expect(await subject.read('v1'), isNull);
    });

    test('견본으로 만든 캐시는 서버 빌드에 내주지 않는다 — 지어낸 대사가 굳는다', () async {
      // 견본(가짜) 빌드가 남긴 파일을 서버 빌드가 읽는 상황. 그대로 내주면
      // 스위치를 켜도 영영 다시 받지 않고, 만화(API-71)도 그 대사로 만들어진다.
      final sample = TranscriptStore(
        transcriber: (_) async => lines(),
        root: () async => temporary,
        serverBuild: false,
      );
      await sample.write('v1', lines());

      var calls = 0;
      final real = TranscriptStore(
        transcriber: (_) async {
          calls++;
          return lines();
        },
        root: () async => temporary,
        serverBuild: true,
      );

      expect(await real.read('v1'), isNull, reason: '견본 캐시는 없는 것으로 본다');
      real.ensure('v1', '/video/v1.mp4');
      await real.pending;
      expect(calls, 1, reason: '다시 받아야 한다');
      expect(await real.read('v1'), hasLength(2), reason: '이번엔 서버 캐시라 읽힌다');
    });

    test('source가 없는 옛 캐시도 서버 빌드는 버리고 다시 받는다 — 던지지 않는다', () async {
      await File('${temporary.path}${Platform.pathSeparator}v1.json')
          .writeAsString(
            '{"version":1,"lines":[{"startMs":0,"endMs":1,"text":"옛 캐시"}]}',
          );
      final real = TranscriptStore(
        transcriber: (_) async => lines(),
        root: () async => temporary,
        serverBuild: true,
      );

      expect(await real.read('v1'), isNull);
    });

    test('캐시 파일이 깨졌으면 null로 읽고 다시 전사한다', () async {
      var calls = 0;
      final subject = store((_) async {
        calls++;
        return lines();
      });
      await File(
        '${temporary.path}${Platform.pathSeparator}v1.json',
      ).writeAsString('{잘린 json');

      expect(await subject.read('v1'), isNull);
      subject.ensure('v1', '/video/v1.mp4');
      await subject.pending;
      expect(calls, 1);
    });
  });
}
