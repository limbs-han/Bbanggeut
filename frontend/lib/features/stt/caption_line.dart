/// 자막 한 줄 — 전사 결과와 편집 결과를 같은 타입으로 다룬다.
///
/// **왜 별도 타입인가**: 이 값은 STT가 만들고, 사용자가 고치고, 내보내기가
/// 네이티브로 넘긴다. 세 곳이 쓰는데 `core/`의 기존 파일을 건드리지 않으려고
/// 여기에 둔다 — 나중에 이 브랜치를 합칠 때 충돌 지점을 줄인다.
///
/// 신뢰도는 담지 않는다. 자막에는 쓸 데가 없고, 4컷 만화가 쓰는 값이라
/// 그쪽에서 붙이면 된다.
library;

class CaptionLine {
  CaptionLine({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;

  /// 사용자가 고칠 수 있다. 시각은 전사가 준 그대로 둔다.
  String text;
}

/// [positionMs]에 보일 자막. 없으면 null.
///
/// 시작 포함·끝 제외로 판정한다 — 끝을 포함하면 붙어 있는 두 줄이 경계에서
/// 동시에 잡힌다. Kotlin 오버레이도 같은 규칙을 쓴다.
String? captionAt(List<CaptionLine> lines, int positionMs) {
  for (final line in lines) {
    if (positionMs >= line.startMs && positionMs < line.endMs) return line.text;
  }
  return null;
}

/// 네이티브에 넘길 자막 목록. 자른 구간 밖은 버리고 시각을 클립 기준으로 옮긴다.
///
/// **왜 옮기나**: 내보내기가 `ClippingConfiguration`으로 자르면 Media3가
/// 오버레이에 주는 시각이 잘린 클립의 0부터 시작한다. 원본 시각을 그대로 넘기면
/// 자막이 `startMs`만큼 늦게 뜬다.
///
/// [endMs]가 [startMs]보다 크지 않으면 자르기가 없는 것으로 본다 (네이티브의
/// 빠른 경로 판정과 같은 규칙).
List<Map<String, Object>> captionsForExport(
  List<CaptionLine> lines, {
  required int startMs,
  required int endMs,
}) {
  final trimming = endMs > startMs;
  final from = trimming ? startMs : 0;
  final to = trimming ? endMs : null;

  final out = <Map<String, Object>>[];
  for (final line in lines) {
    final text = line.text.trim();
    if (text.isEmpty) continue;
    if (to != null && (line.endMs <= from || line.startMs >= to)) continue;

    final start = (line.startMs < from ? from : line.startMs) - from;
    final rawEnd = to != null && line.endMs > to ? to : line.endMs;
    final end = rawEnd - from;
    if (end <= start) continue;

    out.add({'startMs': start, 'endMs': end, 'text': text});
  }
  return out;
}
