/// 서버와 주고받는 4컷 구성.
///
/// **왜 4개를 강제하나**: 그림이 2x2 격자 한 장이고 자막을 각 칸에 얹는다. 컷 수가
/// 다르면 얹을 칸이 안 맞는다. 서버 계약 위반이므로 조용히 넘기지 않고 던진다.
library;

import '../stt/caption_line.dart';

/// 만화는 항상 네 컷이다.
const comicCutCount = 4;

class ComicCut {
  ComicCut({required this.beat, required this.scene, this.dialogue});

  /// 기·승·전·결 중 어디인지. 사용자에게 보여준다.
  final String beat;

  /// 이미지 프롬프트에 들어갈 장면 묘사. 사용자에게도 보여준다.
  final String scene;

  /// 그 컷에서 들린 대사. 없는 컷도 있다(상황만 있는 컷).
  /// 사용자가 고칠 수 있다.
  String? dialogue;
}

/// 서버 응답을 자료형으로 옮긴다. 계약을 어기면 [FormatException]을 던진다.
List<ComicCut> parseComicCuts(Map<String, dynamic> body) {
  final raw = body['cuts'];
  if (raw is! List || raw.length != comicCutCount) {
    throw FormatException(
      '만화는 $comicCutCount컷이어야 합니다 (받은 것: ${raw is List ? raw.length : raw}).',
    );
  }
  return [
    for (final entry in raw)
      ComicCut(
        beat: _required(entry, 'beat'),
        scene: _required(entry, 'scene'),
        dialogue: _dialogue(entry),
      ),
  ];
}

String _required(Object? entry, String key) {
  final value = (entry as Map?)?[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('컷에 $key가 없습니다: $entry');
  }
  return value.trim();
}

/// 빈 문자열은 null로 본다 — 빈 자막 띠를 그리지 않기 위해서다.
String? _dialogue(Object? entry) {
  final value = (entry as Map?)?['dialogue'];
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

List<Map<String, Object?>> cutsToJson(List<ComicCut> cuts) => [
  for (final cut in cuts)
    {'beat': cut.beat, 'scene': cut.scene, 'dialogue': cut.dialogue},
];

/// 서버에 보낼 전사문. **끝 시각은 보내지 않는다** — 구성에 쓰이지 않는다.
List<Map<String, Object>> linesToJson(List<CaptionLine> lines) => [
  for (final line in lines)
    if (line.text.trim().isNotEmpty)
      {'startMs': line.startMs, 'text': line.text.trim()},
];
