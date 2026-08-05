import '../../core/models.dart';

/// 웃음 뽑기에서 남길 수 있는 이모지 반응.
///
/// 서버는 `FUNNY` 같은 대문자 이름만 다루고, 화면 문구와 이모지는 앱이 들고 있다.
enum LaughReactionType {
  funny('FUNNY', '😂', '다시 봐도 웃겨요'),
  missThis('MISS_THIS', '🥹', '이때가 그리워요'),
  goodSave('GOOD_SAVE', '💛', '저장 잘했어요'),
  embarrassing('EMBARRASSING', '🙈', '흑역사 발견'),
  again('AGAIN', '🔁', '다음에 또 해요');

  const LaughReactionType(this.wireName, this.emoji, this.label);

  /// 서버와 주고받는 이름.
  final String wireName;
  final String emoji;
  final String label;

  static LaughReactionType? tryParse(Object? value) {
    if (value == null) return null;
    final name = '$value'.trim().toUpperCase();
    for (final type in values) {
      if (type.wireName == name) return type;
    }
    return null;
  }
}

/// 이 영상에 반응을 남긴 가족 구성원 한 명.
///
/// 프로필 사진은 기기에만 저장되는 값이라 서버가 알지 못한다. 화면은 이름의 첫
/// 글자로 원형 아바타를 그리고, 본인([isMe])만 기기에 저장된 아바타로 바꿔 그린다.
class LaughReactionMember {
  const LaughReactionMember({
    required this.memberId,
    required this.displayName,
    required this.reaction,
    required this.isMe,
  });

  final String memberId;
  final String displayName;
  final LaughReactionType reaction;
  final bool isMe;

  /// 이름이 비어 있어도 아바타에 글자 하나는 들어가야 한다.
  String get initial {
    final name = displayName.trim();
    if (name.isEmpty) return '가';
    // runes로 잘라 이모지나 결합 문자가 반토막 나지 않게 한다.
    return String.fromCharCode(name.runes.first);
  }

  static LaughReactionMember? tryParse(Object? value) {
    if (value is! Map) return null;
    final reaction = LaughReactionType.tryParse(value['reactionType']);
    final memberId = value['memberId'];
    if (reaction == null || memberId == null) return null;
    return LaughReactionMember(
      memberId: '$memberId',
      displayName: value['displayName'] as String? ?? '가족',
      reaction: reaction,
      isMe: value['isMe'] as bool? ?? false,
    );
  }
}

/// 뽑힌 웃음 추억 한 건.
///
/// 영상 부분은 기존 [VideoMemory]를 그대로 쓴다 — 썸네일([MemoryThumbnail])과 상세
/// 재생 화면이 이미 그 모델을 받기 때문에 뽑기 전용 재생기를 새로 만들 필요가 없다.
class LaughMemory {
  const LaughMemory({
    required this.video,
    required this.reactionCounts,
    this.expiresAt,
    this.myReaction,
    this.familyReactions = const [],
  });

  final VideoMemory video;
  final DateTime? expiresAt;

  /// 반응별 개수. 서버 응답을 그대로 쓰고 앱에서 임의로 더하거나 빼지 않는다.
  final Map<LaughReactionType, int> reactionCounts;
  final LaughReactionType? myReaction;

  /// 이 영상에 반응을 남긴 구성원만. 서버가 준 순서를 그대로 쓴다.
  final List<LaughReactionMember> familyReactions;

  String get id => video.id;

  /// 촬영 시각이 비어 있는 예전 데이터는 저장 시각으로 대신 보여 준다.
  DateTime? get capturedAt => video.capturedStartAt ?? video.createdAt;

  int countOf(LaughReactionType type) => reactionCounts[type] ?? 0;

  factory LaughMemory.fromJson(Map<String, dynamic> json) {
    final counts = <LaughReactionType, int>{};
    final raw = json['reactionCounts'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final type = LaughReactionType.tryParse(entry.key);
        final count = entry.value;
        if (type != null && count is num) counts[type] = count.toInt();
      }
    }
    return LaughMemory(
      video: VideoMemory.fromJson(
        (json['video'] as Map).cast<String, dynamic>(),
      ),
      expiresAt: parseDate(json['expiresAt']),
      reactionCounts: Map.unmodifiable(counts),
      myReaction: LaughReactionType.tryParse(json['myReaction']),
      familyReactions: List.unmodifiable(
        (json['familyReactions'] as List? ?? const [])
            .map(LaughReactionMember.tryParse)
            .whereType<LaughReactionMember>(),
      ),
    );
  }
}

/// 뽑기 결과. 꺼낼 추억이 없는 것은 오류가 아니라 정상 상태다.
class LaughDrawResult {
  const LaughDrawResult({required this.hasMemory, this.memory, this.message});

  final bool hasMemory;
  final LaughMemory? memory;
  final String? message;

  factory LaughDrawResult.fromJson(Map<String, dynamic> json) {
    final memory = json['memory'];
    final hasMemory = json['hasMemory'] as bool? ?? memory != null;
    return LaughDrawResult(
      hasMemory: hasMemory && memory is Map,
      memory: memory is Map
          ? LaughMemory.fromJson(memory.cast<String, dynamic>())
          : null,
      message: json['message'] as String?,
    );
  }
}
