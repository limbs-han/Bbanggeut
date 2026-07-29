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

/// 자막 한 줄의 최대 글자 수. 한국어 자막 관례가 한 줄 16~20자다.
const captionMaxChars = 20;

/// 문장 끝을 알리는 부호. **언어에 매이지 않는 유일한 신호다.**
///
/// 한국어 종결어미 목록(요·다·죠·까·네)으로 나눠 봤지만 브리틀했다 — "만지지"의
/// `지`처럼 낱말 안의 글자와 구분할 수 없고, 언어가 바뀌면 통째로 못 쓴다.
/// 구두점만 보고, 나머지는 글자 수로 나눈다.
const _enders = {'.', '?', '!', '…', '。', '！', '？'};

/// 전사 한 덩이를 자막 줄들로 나눈다.
///
/// 구두점이 있으면 그 뒤에서, 그래도 [maxChars]를 넘으면 낱말 경계에서 나눈다.
/// whisper는 구두점을 자주 빼므로 실제로는 글자 수 나눔이 주로 쓰인다.
///
/// 시각은 글자 수 비율로 나눠 주고, 모든 줄이 최소 1ms를 갖게 한다.
List<CaptionLine> splitIntoLines(
  List<CaptionLine> lines, {
  int maxChars = captionMaxChars,
}) {
  final out = <CaptionLine>[];
  for (final line in lines) {
    final chunks = <String>[
      for (final sentence in _sentences(line.text.trim()))
        ..._chunk(sentence, maxChars),
    ];
    final span = line.endMs - line.startMs;
    // 구간이 조각 수보다 짧으면 쪼갤 수 없다 — 어느 조각은 길이 0이 되어 화면에
    // 못 뜨고 내보낼 때도 버려진다. 긴 줄로 두는 편이 낫다.
    if (chunks.length <= 1 || span < chunks.length) {
      out.add(line);
      continue;
    }

    final totalChars = chunks.fold(0, (sum, chunk) => sum + chunk.length);
    var at = line.startMs;
    for (var i = 0; i < chunks.length; i++) {
      final last = i == chunks.length - 1;
      var end = last
          ? line.endMs
          : at + (span * chunks[i].length / totalChars).round();
      // 뒤에 남은 조각들이 각각 최소 1ms를 갖도록 자리를 남겨 둔다. 이걸 안 하면
      // 비율 계산이 앞 조각에 다 주고 마지막 조각이 0ms가 된다 — 그런 줄은
      // 화면에 못 뜨고 내보낼 때도 버려진다.
      final maxEnd = line.endMs - (chunks.length - 1 - i);
      if (end > maxEnd) end = maxEnd;
      if (end <= at) end = at + 1;
      out.add(CaptionLine(startMs: at, endMs: end, text: chunks[i]));
      at = end;
    }
  }
  return out;
}

/// 구두점으로 끝나는 낱말 뒤에서 자른다. 구두점이 없으면 전체가 한 덩이다.
List<String> _sentences(String text) {
  if (text.isEmpty) return const [];

  final out = <String>[];
  var current = <String>[];
  for (final word in text.split(' ')) {
    if (word.isEmpty) continue;
    current.add(word);

    if (_enders.contains(word.substring(word.length - 1))) {
      out.add(current.join(' '));
      current = <String>[];
    }
  }
  if (current.isNotEmpty) out.add(current.join(' '));
  return out;
}

List<String> _chunk(String text, int maxChars) {
  if (text.length <= maxChars) return [text];

  final out = <String>[];
  var current = '';
  void flushOversized() {
    while (current.length > maxChars) {
      out.add(current.substring(0, maxChars));
      current = current.substring(maxChars);
    }
  }

  for (final word in text.split(' ')) {
    if (word.isEmpty) continue;
    if (current.isEmpty) {
      current = word;
    } else if (current.length + 1 + word.length <= maxChars) {
      current = '$current $word';
    } else {
      out.add(current);
      current = word;
    }
    flushOversized();
  }
  if (current.isNotEmpty) out.add(current);
  return out;
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
