// 웃음 뽑기 효과음을 직접 합성해 WAV로 굽는 개발용 스크립트.
//
// **왜 스크립트로 만드는가**: 인터넷에서 받은 효과음은 출처와 저작권이 불분명해
// 제품에 넣을 수 없다. 그래서 파형을 코드로 만들고, 그 코드를 저장소에 남겨
// "이 소리는 이렇게 만들어졌다"를 재현 가능하게 둔다. 외부 자산도, 라이선스
// 확인도 필요 없다.
//
// 실행:
//   dart run tool/generate_laugh_draw_sfx.dart
//
// 결과:
//   assets/audio/laugh_draw_start.wav     — 공이 통 안에서 굴러가는 통통 소리
//   assets/audio/laugh_draw_complete.wav  — 당첨 공이 떨어지는 짧은 반짝임

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _sampleRate = 44100;

void main() {
  final directory = Directory('assets/audio');
  directory.createSync(recursive: true);

  File(
    '${directory.path}/laugh_draw_start.wav',
  ).writeAsBytesSync(_wav(_buildStart()));
  File(
    '${directory.path}/laugh_draw_complete.wav',
  ).writeAsBytesSync(_wav(_buildComplete()));

  stdout.writeln('assets/audio/laugh_draw_start.wav');
  stdout.writeln('assets/audio/laugh_draw_complete.wav');
}

/// 뽑기 시작음: 1.85초.
///
/// 유리통 안에서 공이 서로 부딪히며 굴러가는 소리를 "짧은 통통 소리 여러 개 +
/// 부드러운 굴림 소리"로 만든다. 실제 타악기 샘플이 없으므로 마림바에 가까운
/// 삼각파 배음과 빠르게 사라지는 감쇠 곡선을 쓴다.
Float64List _buildStart() {
  const duration = 1.85;
  final buffer = Float64List((duration * _sampleRate).round());

  // 공이 부딪히는 시점과 음높이. 5음 음계(도-레-미-솔-라)만 써서 어떤 순서로
  // 나도 귀에 거슬리지 않게 한다 — 아이가 들어도 편한 소리가 목표다.
  const scale = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5];
  const hits = <(double, int, double)>[
    // (시작 시각, 음 번호, 세기)
    (0.00, 0, 0.95),
    (0.13, 2, 0.72),
    (0.24, 1, 0.66),
    (0.35, 3, 0.78),
    (0.47, 0, 0.60),
    (0.57, 4, 0.70),
    (0.68, 2, 0.62),
    (0.79, 1, 0.58),
    (0.89, 3, 0.66),
    (0.99, 5, 0.72),
    (1.10, 2, 0.56),
    (1.20, 4, 0.62),
    (1.31, 1, 0.52),
    (1.42, 3, 0.58),
    (1.53, 5, 0.64),
    (1.64, 4, 0.50),
  ];

  for (final (at, note, gain) in hits) {
    _addPluck(buffer, at, scale[note], gain, 0.19);
  }

  // 굴림 소리: 대역이 좁은 잡음을 아주 작게 깔아 "통 안에서 뭔가 돌고 있다"는
  // 느낌을 준다. 크게 넣으면 바람 소리처럼 들려서 세기를 낮게 잡는다.
  final random = math.Random(20260805);
  var rolling = 0.0;
  for (var i = 0; i < buffer.length; i++) {
    final t = i / _sampleRate;
    // 저역만 남기는 1차 필터. 잡음이 쉬익 소리가 되지 않게 한다.
    rolling += (random.nextDouble() * 2 - 1 - rolling) * 0.045;
    // 시작과 끝에서 부드럽게 들어오고 나간다.
    final swell = math.sin(math.pi * (t / duration).clamp(0.0, 1.0));
    // 공이 굴러가는 리듬. 조금씩 빨라진다.
    final wobble = 0.65 + 0.35 * math.sin(2 * math.pi * (2.4 + t * 1.6) * t);
    buffer[i] += rolling * swell * wobble * 0.16;
  }

  return _finish(buffer, fadeOut: 0.12, peak: 0.82);
}

/// 당첨음: 0.52초. 올라가는 세 음 + 짧은 반짝임.
Float64List _buildComplete() {
  const duration = 0.52;
  final buffer = Float64List((duration * _sampleRate).round());

  // 도-미-솔-도(한 옥타브 위)로 올라가며 "당첨!" 느낌을 만든다.
  _addPluck(buffer, 0.00, 659.25, 0.85, 0.16);
  _addPluck(buffer, 0.07, 830.61, 0.85, 0.16);
  _addPluck(buffer, 0.14, 987.77, 0.90, 0.22);
  _addPluck(buffer, 0.21, 1318.51, 0.95, 0.30);

  // 반짝임: 아주 높은 음 두 개를 짧게 얹는다.
  _addPluck(buffer, 0.26, 2093.0, 0.30, 0.14);
  _addPluck(buffer, 0.32, 2637.0, 0.24, 0.12);

  return _finish(buffer, fadeOut: 0.10, peak: 0.86);
}

/// 마림바에 가까운 한 음. 기본음 + 옥타브 + 12도 배음을 섞고 빠르게 감쇠시킨다.
void _addPluck(
  Float64List buffer,
  double startSeconds,
  double frequency,
  double gain,
  double decaySeconds,
) {
  final start = (startSeconds * _sampleRate).round();
  final length = (decaySeconds * _sampleRate).round();
  for (var i = 0; i < length; i++) {
    final index = start + i;
    if (index < 0 || index >= buffer.length) break;
    final t = i / _sampleRate;
    // 지수 감쇠. 타악기처럼 때린 직후 가장 크고 금방 사라진다.
    final envelope = math.exp(-t / (decaySeconds * 0.34));
    // 때리는 순간의 딱 소리(2ms 어택)를 남겨 둔다.
    final attack = math.min(1.0, t / 0.002);
    final wave =
        math.sin(2 * math.pi * frequency * t) +
        0.34 * math.sin(4 * math.pi * frequency * t) +
        0.16 * math.sin(6 * math.pi * frequency * t);
    buffer[index] += wave * envelope * attack * gain * 0.34;
  }
}

/// 클리핑을 막고 끝을 부드럽게 닫는다. 뒤끝이 뚝 끊기면 딱 소리가 난다.
Float64List _finish(
  Float64List buffer, {
  required double fadeOut,
  required double peak,
}) {
  final fadeSamples = (fadeOut * _sampleRate).round();
  var maximum = 0.0;
  for (final sample in buffer) {
    maximum = math.max(maximum, sample.abs());
  }
  final scale = maximum == 0 ? 1.0 : peak / maximum;
  for (var i = 0; i < buffer.length; i++) {
    var value = buffer[i] * scale;
    final remaining = buffer.length - i;
    if (remaining < fadeSamples) value *= remaining / fadeSamples;
    buffer[i] = value;
  }
  return buffer;
}

/// 16bit PCM 모노 WAV 한 덩어리.
Uint8List _wav(Float64List samples) {
  final dataBytes = samples.length * 2;
  final bytes = BytesBuilder();
  void ascii(String value) => bytes.add(value.codeUnits);
  void uint32(int value) => bytes.add(
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little),
  );
  void uint16(int value) => bytes.add(
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little),
  );

  ascii('RIFF');
  uint32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  uint32(16);
  uint16(1); // PCM
  uint16(1); // mono
  uint32(_sampleRate);
  uint32(_sampleRate * 2); // byte rate
  uint16(2); // block align
  uint16(16); // bits per sample
  ascii('data');
  uint32(dataBytes);

  final pcm = Uint8List(dataBytes);
  final view = pcm.buffer.asByteData();
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  bytes.add(pcm);
  return bytes.toBytes();
}
