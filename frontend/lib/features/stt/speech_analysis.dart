/// 발화 구간 검출과 WAV 조작 — 순수 Dart.
///
/// 근거: INTEGRATION_PROMPT.md §3 P2 VadClassifier
///  "짧은 창 RMS + 스펙트럼 평탄도 기반 단순 판정으로 시작.
///   임계값은 AiComicConfig.vadThreshold를 읽어라."
///
/// 스펙트럼 평탄도를 쓰는 이유: RMS만 보면 에어컨 소음·문 닫는 소리도 발화로
/// 잡힌다. 발화는 하모닉이 뚜렷해 스펙트럼이 뾰족하고(평탄도 낮음), 잡음은
/// 에너지가 전 대역에 퍼져 평탄도가 높다. 두 조건을 함께 걸어야 오탐이 준다.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm_wav.dart';

/// 발화로 판정된 구간.
class SpeechRegion {
  const SpeechRegion({required this.start, required this.end});
  final Duration start;
  final Duration end;
  Duration get length => end - start;

  @override
  String toString() =>
      'SpeechRegion(${start.inMilliseconds}~${end.inMilliseconds}ms)';
}

/// 스펙트럼 평탄도(Wiener entropy) = 기하평균 / 산술평균.
/// 백색 잡음은 1에 가깝고, 순음이나 하모닉이 뚜렷한 발화는 0에 가깝다.
double spectralFlatness(List<double> samples) {
  final size = _largestPowerOfTwo(samples.length);
  if (size < 8) return 1;

  final real = List<double>.filled(size, 0);
  final imag = List<double>.filled(size, 0);
  for (var i = 0; i < size; i++) {
    // 해닝 창 — 창 경계에서 생기는 스펙트럼 누설을 줄인다.
    final taper = 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1));
    real[i] = samples[i] * taper;
  }
  _fft(real, imag);

  // DC(bin 0)는 제외한다 — 직류 오프셋이 평탄도를 왜곡한다.
  const floor = 1e-12;
  var logSum = 0.0;
  var linearSum = 0.0;
  var count = 0;
  for (var bin = 1; bin < size ~/ 2; bin++) {
    final power = real[bin] * real[bin] + imag[bin] * imag[bin] + floor;
    logSum += math.log(power);
    linearSum += power;
    count++;
  }
  if (count == 0 || linearSum <= 0) return 1;
  final geometric = math.exp(logSum / count);
  final arithmetic = linearSum / count;
  final flatness = geometric / arithmetic;
  return flatness.isFinite ? flatness.clamp(0.0, 1.0) : 1;
}

int _largestPowerOfTwo(int value) {
  var size = 1;
  while (size * 2 <= value) {
    size *= 2;
  }
  return size;
}

/// 제자리 radix-2 Cooley-Tukey FFT. 길이는 2의 거듭제곱이어야 한다.
void _fft(List<double> real, List<double> imag) {
  final n = real.length;
  // 비트 반전 정렬
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      var swap = real[i];
      real[i] = real[j];
      real[j] = swap;
      swap = imag[i];
      imag[i] = imag[j];
      imag[j] = swap;
    }
  }
  for (var length = 2; length <= n; length <<= 1) {
    final angle = -2 * math.pi / length;
    final half = length ~/ 2;
    for (var start = 0; start < n; start += length) {
      for (var k = 0; k < half; k++) {
        final wr = math.cos(angle * k);
        final wi = math.sin(angle * k);
        final lo = start + k;
        final hi = lo + half;
        final ur = real[lo];
        final ui = imag[lo];
        final vr = real[hi] * wr - imag[hi] * wi;
        final vi = real[hi] * wi + imag[hi] * wr;
        real[lo] = ur + vr;
        imag[lo] = ui + vi;
        real[hi] = ur - vr;
        imag[hi] = ui - vi;
      }
    }
  }
}

/// 짧은 창 RMS + 스펙트럼 평탄도로 발화 구간을 찾는다.
///
/// [energyRatio]는 창 RMS 중앙값 대비 배율이다 — 절대 임계값을 쓰면 녹음
/// 레벨이 다른 기기에서 전부 틀어진다.
/// [noiseFloorPercentile]로 배경 소음 수준을 추정한다.
///
/// 중앙값을 쓰면 안 된다: 발화가 클립의 절반쯤을 차지하면 중앙값 자체가 발화
/// 에너지가 되어 임계값이 발화보다 높아지고, 발화를 하나도 못 잡는다.
/// 조용한 구간이 소수여도 배경 수준을 대표하도록 낮은 백분위수를 쓴다.
///
/// [absoluteFloor]는 디지털 무음(0)일 때 임계값이 0으로 내려가 아주 작은
/// 잡음까지 후보로 올리는 것을 막는 하한이다(약 -48dBFS).
List<SpeechRegion> detectSpeechRegions(
  PcmWav wav, {
  Duration window = const Duration(milliseconds: 32),
  double energyRatio = 2.0,
  double flatnessCeiling = 0.35,
  double noiseFloorPercentile = 0.2,
  double absoluteFloor = 0.004,
  Duration minLength = const Duration(milliseconds: 250),
  Duration mergeGap = const Duration(milliseconds: 200),
}) {
  final framesPerWindow = (wav.sampleRate * window.inMicroseconds / 1000000)
      .round();
  if (framesPerWindow < 8 || wav.frameCount < framesPerWindow) return const [];

  final windowCount = wav.frameCount ~/ framesPerWindow;
  final energies = List<double>.filled(windowCount, 0);
  final monoWindows = <List<double>>[];
  for (var w = 0; w < windowCount; w++) {
    final mono = List<double>.filled(framesPerWindow, 0);
    var sumSquares = 0.0;
    for (var f = 0; f < framesPerWindow; f++) {
      var mixed = 0.0;
      for (var channel = 0; channel < wav.channels; channel++) {
        mixed +=
            wav.samples[(w * framesPerWindow + f) * wav.channels + channel];
      }
      mixed = mixed / wav.channels / 32768.0;
      mono[f] = mixed;
      sumSquares += mixed * mixed;
    }
    energies[w] = math.sqrt(sumSquares / framesPerWindow);
    monoWindows.add(mono);
  }

  final sorted = [...energies]..sort();
  final index = (sorted.length * noiseFloorPercentile).floor().clamp(
    0,
    sorted.length - 1,
  );
  final noiseFloor = sorted[index];
  final floor = math.max(noiseFloor * energyRatio, absoluteFloor);

  final voiced = List<bool>.filled(windowCount, false);
  for (var w = 0; w < windowCount; w++) {
    if (energies[w] < floor) continue;
    voiced[w] = spectralFlatness(monoWindows[w]) < flatnessCeiling;
  }

  // 연속 구간으로 묶고, 짧은 공백은 이어 붙인다(단어 사이 숨).
  final gapWindows = (mergeGap.inMicroseconds / window.inMicroseconds).round();
  final regions = <SpeechRegion>[];
  var start = -1;
  var silence = 0;
  for (var w = 0; w <= windowCount; w++) {
    final isVoiced = w < windowCount && voiced[w];
    if (isVoiced) {
      start = start < 0 ? w : start;
      silence = 0;
    } else if (start >= 0) {
      silence++;
      if (silence > gapWindows || w == windowCount) {
        final end = w - silence + 1;
        regions.add(SpeechRegion(start: window * start, end: window * end));
        start = -1;
        silence = 0;
      }
    }
  }
  return regions
      .where((region) => region.length >= minLength)
      .toList(growable: false);
}

/// 전체 길이 대비 발화 구간이 차지하는 비율. VadClassifier가 임계값과 비교한다.
double speechRatio(PcmWav wav, List<SpeechRegion> regions) {
  final total = wav.duration.inMicroseconds;
  if (total <= 0) return 0;
  final voiced = regions.fold<int>(
    0,
    (sum, region) => sum + region.length.inMicroseconds,
  );
  return (voiced / total).clamp(0.0, 1.0);
}

/// [start]~[end] 구간만 잘라낸다. STT에 발화 구간만 따로 넘길 때 쓴다.
PcmWav sliceWav(PcmWav wav, Duration start, Duration end) {
  int frameAt(Duration at) => (at.inMicroseconds * wav.sampleRate / 1000000)
      .round()
      .clamp(0, wav.frameCount);
  final from = frameAt(start);
  final to = frameAt(end) > from ? frameAt(end) : from;
  return PcmWav(
    samples: Int16List.sublistView(
      wav.samples,
      from * wav.channels,
      to * wav.channels,
    ),
    sampleRate: wav.sampleRate,
    channels: wav.channels,
  );
}

/// 모노로 접고 [targetSampleRate]로 리샘플한다.
///
/// 네이티브(MediaCodec)는 원본 샘플레이트로만 PCM을 내주므로 16kHz 변환은
/// 여기서 한다 — 네이티브 코드를 최소로 남기고, 검증 가능한 로직은 Dart에 둔다.
/// 선형 보간이라 오디오 품질용으로는 거칠지만 VAD·STT 입력으로는 충분하다.
PcmWav resample(PcmWav wav, int targetSampleRate) {
  if (targetSampleRate <= 0 || wav.sampleRate <= 0 || wav.frameCount == 0) {
    return PcmWav(
      samples: Int16List(0),
      sampleRate: targetSampleRate > 0 ? targetSampleRate : 16000,
      channels: 1,
    );
  }

  double monoAt(int frame) {
    var mixed = 0.0;
    for (var channel = 0; channel < wav.channels; channel++) {
      mixed += wav.samples[frame * wav.channels + channel];
    }
    return mixed / wav.channels;
  }

  if (targetSampleRate == wav.sampleRate && wav.channels == 1) return wav;

  final targetFrames = (wav.frameCount * targetSampleRate / wav.sampleRate)
      .floor();
  final output = Int16List(targetFrames);
  final ratio = wav.sampleRate / targetSampleRate;
  for (var i = 0; i < targetFrames; i++) {
    final position = i * ratio;
    final low = position.floor();
    final high = low + 1 < wav.frameCount ? low + 1 : low;
    final fraction = position - low;
    final value = monoAt(low) * (1 - fraction) + monoAt(high) * fraction;
    output[i] = value.round().clamp(-32768, 32767);
  }
  return PcmWav(samples: output, sampleRate: targetSampleRate, channels: 1);
}

/// 헤더 없는 원시 16bit 리틀엔디언 PCM.
///
/// Android 파일 음성 인식(`EXTRA_AUDIO_SOURCE`)은 컨테이너가 아니라 원시 PCM과
/// 별도 메타데이터(인코딩·샘플레이트·채널 수)를 받는다. WAV를 그대로 넘기면
/// 44바이트 헤더가 오디오 샘플로 해석돼 앞부분에 잡음이 섞인다. 헤더 파싱을
/// 네이티브에 넣는 대신 여기서 원시 PCM을 만들어 네이티브 코드를 최소로 둔다.
Uint8List encodePcm16(PcmWav wav) {
  final bytes = ByteData(wav.samples.length * 2);
  for (var i = 0; i < wav.samples.length; i++) {
    bytes.setInt16(i * 2, wav.samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// PcmWav를 RIFF/WAVE 바이트로 직렬화한다.
Uint8List encodeWav(PcmWav wav) {
  final dataSize = wav.samples.length * 2;
  final bytes = ByteData(44 + dataSize);
  void tag(int offset, String value) {
    for (var i = 0; i < 4; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, wav.channels, Endian.little);
  bytes.setUint32(24, wav.sampleRate, Endian.little);
  bytes.setUint32(28, wav.sampleRate * wav.channels * 2, Endian.little);
  bytes.setUint16(32, wav.channels * 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < wav.samples.length; i++) {
    bytes.setInt16(44 + i * 2, wav.samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}
