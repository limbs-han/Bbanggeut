DateTime? parseDate(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

String normalizeRole(Object? value) {
  final role = '$value'.trim().toUpperCase();
  return switch (role) {
    'OWNER' || '소유자' => 'OWNER',
    'MEMBER' || 'VIEWER' || 'EDITOR' || '멤버' || '구성원' || '뷰어' => 'MEMBER',
    _ => 'MEMBER',
  };
}

String normalizeVideoTrigger(Object? value) {
  final trigger = '$value'.trim().toUpperCase();
  return switch (trigger) {
    'LAUGH' || 'LAUGHTER' || 'SMILE' || '웃음' || '웃음 감지' => 'LAUGHTER',
    'EDIT' || 'EDITED' || 'EDIT_OUTPUT' || '편집' => 'EDIT',
    '' || 'NULL' => 'MANUAL',
    _ => trigger,
  };
}

List<String> normalizeVideoEventTypes(
  Object? value, {
  required String triggerType,
}) {
  final requested = value is List
      ? value.map(normalizeVideoTrigger)
      : const <String>[];
  final normalized = <String>[];

  for (final eventType in [triggerType, ...requested]) {
    if (eventType.isNotEmpty && !normalized.contains(eventType)) {
      normalized.add(eventType);
    }
  }

  return List.unmodifiable(normalized);
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.displayName,
  });
  final String id;
  final String email;
  final String displayName;
  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String? ?? '',
    email: json['email'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
  );
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.deviceId,
    this.resourceId,
    this.readAt,
  });

  final String id;
  final String type;
  final String title;
  final String body;
  final String? deviceId;
  final String? resourceId;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;

  AppNotification copyWith({DateTime? readAt}) => AppNotification(
    id: id,
    type: type,
    title: title,
    body: body,
    deviceId: deviceId,
    resourceId: resourceId,
    readAt: readAt ?? this.readAt,
    createdAt: createdAt,
  );

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as String,
        type: json['type'] as String? ?? '',
        title: json['title'] as String? ?? '빵긋',
        body: json['body'] as String? ?? '',
        deviceId: json['deviceId'] as String?,
        resourceId: json['resourceId'] as String?,
        readAt: parseDate(json['readAt']),
        createdAt: parseDate(json['createdAt']) ?? DateTime.now(),
      );
}

class MembershipRequestLink {
  const MembershipRequestLink({required this.token, required this.expiresAt});
  final String token;
  final DateTime? expiresAt;
  factory MembershipRequestLink.fromJson(Map<String, dynamic> json) =>
      MembershipRequestLink(
        token: json['token'] as String,
        expiresAt: parseDate(json['expiresAt']),
      );
}

class MembershipRequestPreview {
  const MembershipRequestPreview({
    required this.email,
    required this.displayName,
    required this.expiresAt,
  });
  final String email;
  final String displayName;
  final DateTime? expiresAt;
  factory MembershipRequestPreview.fromJson(Map<String, dynamic> json) =>
      MembershipRequestPreview(
        email: json['email'] as String,
        displayName: json['displayName'] as String? ?? '',
        expiresAt: parseDate(json['expiresAt']),
      );
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.user,
  });
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final UserProfile user;
  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String,
    expiresIn: (json['expiresIn'] as num?)?.toInt() ?? 0,
    user: UserProfile.fromJson(json['user'] as Map<String, dynamic>),
  );
}

class DeviceSummary {
  const DeviceSummary({
    required this.id,
    required this.name,
    required this.model,
    required this.status,
    required this.myRole,
    required this.retentionDays,
    this.lastSeenAt,
  });
  final String id;
  final String name;
  final String model;
  final String status;
  final String myRole;
  final int retentionDays;
  final DateTime? lastSeenAt;
  bool get isOnline => status == 'ONLINE';
  bool get isOwner => normalizeRole(myRole) == 'OWNER';
  bool get canEditVideos => isOwner || myRole.trim().toUpperCase() == 'EDITOR';
  factory DeviceSummary.fromJson(Map<String, dynamic> json) => DeviceSummary(
    id: json['id'] as String,
    name: json['name'] as String? ?? '내 카메라',
    model: json['model'] as String? ?? '',
    status: json['status'] as String? ?? 'OFFLINE',
    myRole: normalizeRole(json['myRole']),
    retentionDays: (json['retentionDays'] as num?)?.toInt() ?? 30,
    lastSeenAt: parseDate(json['lastSeenAt']),
  );
}

class VaultDevice {
  const VaultDevice({
    required this.bindingId,
    required this.generation,
    required this.device,
  });

  final String bindingId;
  final int generation;
  final DeviceSummary device;

  factory VaultDevice.fromJson(
    Map<String, dynamic> json, {
    required String myRole,
    required int retentionDays,
  }) => VaultDevice(
    bindingId: json['bindingId'] as String,
    generation: (json['generation'] as num?)?.toInt() ?? 1,
    device: DeviceSummary(
      id: json['deviceId'] as String,
      name: json['name'] as String? ?? '내 카메라',
      model: json['model'] as String? ?? '',
      status: json['status'] as String? ?? 'OFFLINE',
      myRole: myRole,
      retentionDays: retentionDays,
      lastSeenAt: parseDate(json['lastSeenAt']),
    ),
  );
}

class MemoryVault {
  const MemoryVault({
    required this.id,
    required this.name,
    required this.status,
    required this.myRole,
    required this.retentionDays,
    required this.subscriptionActive,
    required this.devices,
    this.subscriptionGraceUntil,
  });

  final String id;
  final String name;
  final String status;
  final String myRole;
  final int retentionDays;
  final bool subscriptionActive;
  final DateTime? subscriptionGraceUntil;
  final List<VaultDevice> devices;

  bool get isOwner => normalizeRole(myRole) == 'OWNER';
  bool get hasConnectedDevice => devices.isNotEmpty;

  factory MemoryVault.fromJson(Map<String, dynamic> json) {
    final role = normalizeRole(json['myRole']);
    final retention = (json['retentionDays'] as num?)?.toInt() ?? 30;
    return MemoryVault(
      id: json['id'] as String,
      name: json['name'] as String? ?? '나의 추억',
      status: json['status'] as String? ?? 'ACTIVE',
      myRole: role,
      retentionDays: retention,
      subscriptionActive: json['subscriptionActive'] as bool? ?? false,
      subscriptionGraceUntil: parseDate(json['subscriptionGraceUntil']),
      devices: (json['devices'] as List? ?? const [])
          .map(
            (item) => VaultDevice.fromJson(
              item as Map<String, dynamic>,
              myRole: role,
              retentionDays: retention,
            ),
          )
          .toList(growable: false),
    );
  }
}

class DeviceStatus {
  const DeviceStatus({
    required this.status,
    required this.recording,
    required this.uploadQueueDepth,
    this.bufferSeconds,
    this.personCount,
  });
  final String status;
  final bool recording;
  final int uploadQueueDepth;
  final int? bufferSeconds;

  /// Number of people the edge last detected in frame. Null when the device
  /// has not reported presence (e.g. detection off or never seen online).
  final int? personCount;
  bool get isOnline => status == 'ONLINE';
  factory DeviceStatus.fromJson(Map<String, dynamic> json) => DeviceStatus(
    status: json['status'] as String? ?? 'OFFLINE',
    recording: json['recording'] as bool? ?? false,
    uploadQueueDepth: (json['uploadQueueDepth'] as num?)?.toInt() ?? 0,
    bufferSeconds: (json['bufferSeconds'] as num?)?.toInt(),
    personCount: (json['personCount'] as num?)?.toInt(),
  );
}

/// One-call aggregate for the home dashboard: today's counts plus the latest
/// highlight. Backed by `GET /api/devices/{deviceId}/home-summary`.
class HomeSummary {
  const HomeSummary({
    required this.captureCount,
    required this.savedCount,
    required this.memoCount,
    this.latestHighlight,
  });
  final int captureCount;
  final int savedCount;
  final int memoCount;
  final VideoMemory? latestHighlight;
  factory HomeSummary.fromJson(Map<String, dynamic> json) => HomeSummary(
    captureCount: (json['captureCount'] as num?)?.toInt() ?? 0,
    savedCount: (json['savedCount'] as num?)?.toInt() ?? 0,
    memoCount: (json['memoCount'] as num?)?.toInt() ?? 0,
    latestHighlight: json['latestHighlight'] == null
        ? null
        : VideoMemory.fromJson(json['latestHighlight'] as Map<String, dynamic>),
  );
}

class VideoMemory {
  const VideoMemory({
    required this.id,
    required this.deviceId,
    required this.triggerType,
    required this.title,
    required this.status,
    required this.favorite,
    this.eventTypes = const [],
    this.sourceType = 'IOT_CAPTURE',
    this.durationMs,
    this.thumbnailUrl,
    this.capturedStartAt,
    this.createdAt,
  });
  final String id;
  final String deviceId;
  final String triggerType;
  final List<String> eventTypes;
  final String title;
  final String status;
  final bool favorite;
  final String sourceType;
  final int? durationMs;
  final String? thumbnailUrl;
  final DateTime? capturedStartAt;
  final DateTime? createdAt;

  /// 서버 응답을 다시 받지 않고 방금 바꾼 값만 갈아 끼울 때 쓴다. 목록을
  /// 통째로 다시 조회하면 사용자는 자기가 누른 결과를 몇 초 뒤에 본다.
  VideoMemory copyWith({String? title, bool? favorite}) => VideoMemory(
    id: id,
    deviceId: deviceId,
    triggerType: triggerType,
    eventTypes: eventTypes,
    sourceType: sourceType,
    title: title ?? this.title,
    status: status,
    favorite: favorite ?? this.favorite,
    durationMs: durationMs,
    thumbnailUrl: thumbnailUrl,
    capturedStartAt: capturedStartAt,
    createdAt: createdAt,
  );
  List<String> get effectiveEventTypes => eventTypes.isEmpty
      ? List.unmodifiable([triggerType])
      : eventTypes;
  bool hasEventType(String eventType) =>
      effectiveEventTypes.contains(normalizeVideoTrigger(eventType));

  /// 편집 완성본인가.
  ///
  /// `triggerType`이나 `eventTypes`로는 판정할 수 없다 — 서버가 편집본 행을
  /// 만들 때 원본의 trigger_type과 event_types를 그대로 물려주기 때문이다
  /// (`VideoMapper.insertEditOutput`). 웃음 클립을 편집하면 편집본도
  /// `LAUGHTER`를 들고 있다. 구분은 `sourceType`으로만 한다.
  bool get isEditOutput => sourceType == 'EDIT_OUTPUT';

  factory VideoMemory.fromJson(Map<String, dynamic> json) {
    final triggerType = normalizeVideoTrigger(
      json['triggerType'] ?? json['eventType'] ?? json['category'],
    );
    return VideoMemory(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      triggerType: triggerType,
      eventTypes: normalizeVideoEventTypes(
        json['eventTypes'],
        triggerType: triggerType,
      ),
      title: json['title'] as String? ?? '이름 없는 추억',
      status: json['status'] as String? ?? 'PROCESSING',
      favorite: json['isFavorite'] as bool? ?? false,
      sourceType: json['sourceType'] as String? ?? 'IOT_CAPTURE',
      durationMs: (json['durationMs'] as num?)?.toInt(),
      thumbnailUrl: json['thumbnailUrl'] as String?,
      capturedStartAt: parseDate(json['capturedStartAt']),
      createdAt: parseDate(json['createdAt']),
    );
  }
}

class VideoPage {
  const VideoPage({
    required this.items,
    this.nextCursor,
    required this.hasNext,
  });
  final List<VideoMemory> items;
  final String? nextCursor;
  final bool hasNext;
  factory VideoPage.fromJson(Map<String, dynamic> json) => VideoPage(
    items: (json['items'] as List? ?? const [])
        .map((e) => VideoMemory.fromJson(e as Map<String, dynamic>))
        .toList(),
    nextCursor: json['nextCursor'] as String?,
    hasNext: json['hasNext'] as bool? ?? false,
  );
}

class VideoStats {
  const VideoStats({
    required this.totalCount,
    required this.byTriggerType,
    this.dailyCounts = const [],
    this.peakWeekday,
    this.peakHour,
  });
  final int totalCount;
  final Map<String, int> byTriggerType;
  final List<DailyVideoCount> dailyCounts;
  final NamedVideoCount? peakWeekday;
  final NamedVideoCount? peakHour;
  factory VideoStats.fromJson(Map<String, dynamic> json) => VideoStats(
    totalCount: (json['totalCount'] as num?)?.toInt() ?? 0,
    byTriggerType: {
      for (final item in (json['byTriggerType'] as List? ?? const []))
        normalizeVideoTrigger(item['name']): (item['count'] as num).toInt(),
    },
    dailyCounts: (json['dailyCounts'] as List? ?? const [])
        .map((item) => DailyVideoCount.fromJson(item as Map<String, dynamic>))
        .toList(),
    peakWeekday: json['peakWeekday'] == null
        ? null
        : NamedVideoCount.fromJson(json['peakWeekday'] as Map<String, dynamic>),
    peakHour: json['peakHour'] == null
        ? null
        : NamedVideoCount.fromJson(json['peakHour'] as Map<String, dynamic>),
  );
}

class NamedVideoCount {
  const NamedVideoCount({required this.name, required this.count});
  final String name;
  final int count;
  factory NamedVideoCount.fromJson(Map<String, dynamic> json) =>
      NamedVideoCount(
        name: json['name'] as String? ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );
}

class DailyVideoCount {
  const DailyVideoCount({required this.date, required this.count});
  final DateTime? date;
  final int count;
  factory DailyVideoCount.fromJson(Map<String, dynamic> json) =>
      DailyVideoCount(
        date: parseDate(json['date']),
        count: (json['count'] as num?)?.toInt() ?? 0,
      );
}

/// API-46 이벤트 전용 통계. 웃음 리포트가 `type=LAUGHTER`로 일별 추이를 얻는다.
class EventStats {
  const EventStats({
    required this.detectedCount,
    required this.uploadedVideoCount,
    this.byType = const {},
    this.dailyCounts = const [],
  });
  final int detectedCount;
  final int uploadedVideoCount;
  final Map<String, int> byType;
  final List<DailyVideoCount> dailyCounts;
  factory EventStats.fromJson(Map<String, dynamic> json) => EventStats(
    detectedCount: (json['detectedCount'] as num?)?.toInt() ?? 0,
    uploadedVideoCount: (json['uploadedVideoCount'] as num?)?.toInt() ?? 0,
    byType: {
      for (final item in (json['byType'] as List? ?? const []))
        item['name'] as String: (item['count'] as num).toInt(),
    },
    dailyCounts: (json['dailyCounts'] as List? ?? const [])
        .map((item) => DailyVideoCount.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

/// 영상 댓글. 작성자 표시 이름은 서버가 users에서 조인해 준다 — 앱이 보낸
/// 이름을 믿지 않으므로 위조할 수 없다.
class VideoComment {
  const VideoComment({
    required this.id,
    required this.authorId,
    required this.body,
    this.authorName,
    this.createdAt,
  });
  final String id;
  final String authorId;
  final String body;
  final String? authorName;
  final DateTime? createdAt;
  factory VideoComment.fromJson(Map<String, dynamic> json) => VideoComment(
    id: json['id'] as String? ?? '',
    authorId: json['authorId'] as String? ?? '',
    body: json['body'] as String? ?? '',
    authorName: json['authorName'] as String?,
    createdAt: parseDate(json['createdAt']),
  );
}

/// 만화 피드 한 장.
///
/// 그림은 여기 없다. 만화 PNG는 단기 서명 URL로만 받을 수 있어서 목록에 담으면
/// 화면에 보이지도 않는 만화의 URL까지 발급하고 그 사이 만료된다. 화면에 들어온
/// 카드만 따로 받는다.
class VaultComic {
  const VaultComic({
    required this.videoId,
    required this.title,
    this.customTitle = false,
    this.madeAt,
    this.likeCount = 0,
    this.likedByMe = false,
    this.commentCount = 0,
  });

  final String videoId;

  /// 보여 줄 제목. 붙인 제목이 없으면 서버가 원본 영상 제목을 넣어 준다.
  final String title;

  /// 사용자가 제목을 붙였는가. 제목 고치기 창의 기본값을 가른다.
  final bool customTitle;
  final DateTime? madeAt;
  final int likeCount;
  final bool likedByMe;
  final int commentCount;

  factory VaultComic.fromJson(Map<String, dynamic> json) => VaultComic(
    videoId: json['videoId'] as String? ?? '',
    title: json['title'] as String? ?? '4컷 만화',
    customTitle: json['customTitle'] as bool? ?? false,
    madeAt: parseDate(json['madeAt']),
    likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
    likedByMe: json['likedByMe'] as bool? ?? false,
    commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
  );

  VaultComic copyWith({
    String? title,
    bool? customTitle,
    int? likeCount,
    bool? likedByMe,
    int? commentCount,
  }) => VaultComic(
    videoId: videoId,
    title: title ?? this.title,
    customTitle: customTitle ?? this.customTitle,
    madeAt: madeAt,
    likeCount: likeCount ?? this.likeCount,
    likedByMe: likedByMe ?? this.likedByMe,
    commentCount: commentCount ?? this.commentCount,
  );
}

/// API-80 금고(가족) 단위 이벤트 통계. 기기별 분해(byDevice)를 함께 준다.
class VaultEventStats {
  const VaultEventStats({
    required this.detectedCount,
    this.dailyCounts = const [],
    this.byDevice = const [],
  });
  final int detectedCount;
  final List<DailyVideoCount> dailyCounts;
  final List<VaultDeviceCount> byDevice;
  factory VaultEventStats.fromJson(Map<String, dynamic> json) => VaultEventStats(
    detectedCount: (json['detectedCount'] as num?)?.toInt() ?? 0,
    dailyCounts: (json['dailyCounts'] as List? ?? const [])
        .map((item) => DailyVideoCount.fromJson(item as Map<String, dynamic>))
        .toList(),
    byDevice: (json['byDevice'] as List? ?? const [])
        .map((item) => VaultDeviceCount.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class VaultDeviceCount {
  const VaultDeviceCount({
    required this.deviceId,
    required this.name,
    required this.count,
  });
  final String deviceId;
  final String name;
  final int count;
  factory VaultDeviceCount.fromJson(Map<String, dynamic> json) =>
      VaultDeviceCount(
        deviceId: json['deviceId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );
}

/// 알림 설정(API-78·79). 서버 행이 없으면 모두 켜진 것으로 취급된다.
class NotificationPreferences {
  const NotificationPreferences({
    required this.anniversaryAlerts,
    required this.weeklyReport,
    required this.newMemoryAlerts,
  });
  const NotificationPreferences.defaults()
    : anniversaryAlerts = true,
      weeklyReport = true,
      newMemoryAlerts = true;
  final bool anniversaryAlerts;
  final bool weeklyReport;
  final bool newMemoryAlerts;
  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      NotificationPreferences(
        anniversaryAlerts: json['anniversaryAlerts'] as bool? ?? true,
        weeklyReport: json['weeklyReport'] as bool? ?? true,
        newMemoryAlerts: json['newMemoryAlerts'] as bool? ?? true,
      );
  Map<String, dynamic> toJson() => {
    'anniversaryAlerts': anniversaryAlerts,
    'weeklyReport': weeklyReport,
    'newMemoryAlerts': newMemoryAlerts,
  };
}

/// 캘린더 일정(기념일). 서버 일정 CRUD(API-74~77)와 같은 스키마다.
/// 금고 구성원이 함께 보는 일정.
///
/// [authorId]는 이 일정을 적은 사람이다. 수정·삭제는 적은 사람과 금고 OWNER만
/// 할 수 있어서, 버튼을 가리려면 앱도 누가 적었는지 알아야 한다.
/// 금고의 장소 배치와 내 기기 순서.
///
/// [places]와 [devicePlaces]는 금고 공통이다 — 장소 이름과 기기가 어느 장소에
/// 있는지는 집의 사실이라 가족이 함께 본다. [deviceOrder]는 이 사람만의
/// 순서다 — 기기를 어떤 순서로 볼지는 보기 취향이다.
class PlaceLayout {
  const PlaceLayout({
    this.places = const [],
    this.devicePlaces = const {},
    this.deviceOrder = const [],
  });

  final List<String> places;
  final Map<String, String> devicePlaces;
  final List<String> deviceOrder;

  /// 서버에 아직 아무 배치도 없는가. 이 폰의 로컬 배치를 한 번 올려야 하는지
  /// 판단하는 기준이다.
  bool get isEmpty => places.isEmpty;

  factory PlaceLayout.fromJson(Map<String, dynamic> json) => PlaceLayout(
    places: (json['places'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false),
    devicePlaces: {
      for (final entry in (json['devicePlaces'] as Map? ?? const {}).entries)
        '${entry.key}': '${entry.value}',
    },
    deviceOrder: (json['deviceOrder'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false),
  );
}

class CalendarSchedule {
  const CalendarSchedule({
    required this.id,
    required this.title,
    required this.date,
    this.memo = '',
    this.yearly = false,
    this.emoji = '❤️',
    this.authorId,
    this.authorName,
    this.vaultId,
  });

  final String id;
  final String title;
  final DateTime date;
  final String memo;
  final bool yearly;
  final String emoji;
  final String? authorId;
  final String? authorName;

  /// 어느 금고에 넣을지. 보내지 않으면 서버가 사용자의 금고가 하나일 때만
  /// 알아서 정한다.
  final String? vaultId;

  /// 이 일정을 내가 고치고 지울 수 있는가.
  bool canManage({required String? myUserId, required bool isOwner}) =>
      isOwner || (authorId != null && authorId == myUserId);

  factory CalendarSchedule.fromJson(Map<String, dynamic> json) =>
      CalendarSchedule(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        date: parseDate(json['date']) ?? DateTime.now(),
        memo: json['memo'] as String? ?? '',
        yearly: json['yearly'] as bool? ?? false,
        emoji: json['emoji'] as String? ?? '❤️',
        authorId: json['authorId'] as String?,
        authorName: json['authorName'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'title': title,
    'date':
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
    'memo': memo,
    'yearly': yearly,
    'emoji': emoji,
    'vaultId': ?vaultId,
  };

  CalendarSchedule copyWith({
    String? id,
    String? title,
    DateTime? date,
    String? memo,
    bool? yearly,
    String? emoji,
    String? vaultId,
  }) => CalendarSchedule(
    id: id ?? this.id,
    title: title ?? this.title,
    date: date ?? this.date,
    memo: memo ?? this.memo,
    yearly: yearly ?? this.yearly,
    emoji: emoji ?? this.emoji,
    authorId: authorId,
    authorName: authorName,
    vaultId: vaultId ?? this.vaultId,
  );
}

const calendarScheduleEmojis = [
  '❤️',
  '🎂',
  '🍚',
  '☎️',
  '📷',
  '⭐',
  '🎁',
  '🌸',
  '🎉',
  '✈️',
  '🏠',
  '🐾',
];

class DeviceMember {
  const DeviceMember({
    required this.id,
    required this.user,
    required this.role,
    required this.status,
    this.joinedAt,
  });
  final String id;
  final UserProfile user;
  final String role;
  final String status;
  final DateTime? joinedAt;
  factory DeviceMember.fromJson(Map<String, dynamic> json) => DeviceMember(
    id: json['id'] as String,
    user: UserProfile.fromJson(json['user'] as Map<String, dynamic>),
    role: normalizeRole(json['role']),
    status: json['status'] as String? ?? 'ACTIVE',
    joinedAt: parseDate(json['joinedAt']),
  );
}

class UserSummary {
  const UserSummary({
    required this.id,
    required this.email,
    required this.displayName,
  });
  final String id;
  final String email;
  final String displayName;
  factory UserSummary.fromJson(Map<String, dynamic> json) => UserSummary(
    id: json['id'] as String? ?? '',
    email: json['email'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
  );
}

class Invitation {
  const Invitation({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.inviteeEmail,
    required this.role,
    required this.status,
    this.inviter,
    this.expiresAt,
    this.createdAt,
    this.vaultId,
    this.vaultName,
  });
  final String id;
  final String deviceId;
  final String deviceName;
  final String inviteeEmail;
  final String role;
  final UserSummary? inviter;
  final String status;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final String? vaultId;
  final String? vaultName;
  bool get isPending => status == 'PENDING';
  factory Invitation.fromJson(Map<String, dynamic> json) => Invitation(
    id: json['id'] as String? ?? '',
    deviceId: json['deviceId'] as String? ?? '',
    deviceName: json['deviceName'] as String? ?? '카메라',
    inviteeEmail: json['inviteeEmail'] as String? ?? '',
    role: json['role'] as String? ?? 'VIEWER',
    inviter: json['inviter'] is Map<String, dynamic>
        ? UserSummary.fromJson(json['inviter'] as Map<String, dynamic>)
        : null,
    status: json['status'] as String? ?? 'PENDING',
    expiresAt: parseDate(json['expiresAt']),
    createdAt: parseDate(json['createdAt']),
    vaultId: json['vaultId'] as String?,
    vaultName: json['vaultName'] as String?,
  );
}

class StreamSession {
  const StreamSession({
    required this.id,
    required this.status,
    required this.heartbeatIntervalSeconds,
    this.whepUrl,
    this.viewerExpiresAt,
    this.failureCode,
  });
  final String id;
  final String status;
  final String? whepUrl;
  final int heartbeatIntervalSeconds;
  final DateTime? viewerExpiresAt;
  final String? failureCode;
  bool get isReady => status == 'READY' && whepUrl != null;
  factory StreamSession.fromJson(Map<String, dynamic> json) => StreamSession(
    id: json['sessionId'] as String,
    status: json['status'] as String? ?? 'PENDING',
    whepUrl: json['whepUrl'] as String?,
    heartbeatIntervalSeconds:
        (json['heartbeatIntervalSeconds'] as num?)?.toInt() ?? 15,
    viewerExpiresAt: parseDate(json['viewerExpiresAt']),
    failureCode: json['failureCode'] as String?,
  );
}

class TalkbackSession {
  const TalkbackSession({
    required this.sessionId,
    required this.whipUrl,
    this.expiresAt,
  });
  final String sessionId;
  final String whipUrl;
  final DateTime? expiresAt;
  factory TalkbackSession.fromJson(Map<String, dynamic> json) =>
      TalkbackSession(
        sessionId: json['sessionId'] as String,
        whipUrl: json['whipUrl'] as String,
        expiresAt: parseDate(json['expiresAt']),
      );
}

class SignedUrl {
  const SignedUrl({required this.url, this.expiresAt});
  final String url;
  final DateTime? expiresAt;
  factory SignedUrl.fromJson(Map<String, dynamic> json) => SignedUrl(
    url: json['url'] as String,
    expiresAt: parseDate(json['expiresAt']),
  );
}

class SubscriptionInfo {
  const SubscriptionInfo({
    required this.active,
    required this.premiumRetentionDays,
    this.graceUntil,
  });
  final bool active;
  final int premiumRetentionDays;
  final DateTime? graceUntil;
  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) =>
      SubscriptionInfo(
        active: json['active'] as bool? ?? false,
        premiumRetentionDays:
            (json['premiumRetentionDays'] as num?)?.toInt() ?? 365,
        graceUntil: parseDate(json['graceUntil']),
      );
}

class AccessLogEntry {
  const AccessLogEntry({
    required this.id,
    required this.action,
    required this.outcome,
    this.reasonCode,
    this.createdAt,
  });
  final int id;
  final String action;
  final String outcome;
  final String? reasonCode;
  final DateTime? createdAt;
  factory AccessLogEntry.fromJson(Map<String, dynamic> json) => AccessLogEntry(
    id: (json['id'] as num).toInt(),
    action: json['action'] as String? ?? 'UNKNOWN',
    outcome: json['outcome'] as String? ?? 'SUCCESS',
    reasonCode: json['reasonCode'] as String?,
    createdAt: parseDate(json['createdAt']),
  );
}

class AccessLogPage {
  const AccessLogPage({
    required this.items,
    this.nextCursor,
    required this.hasNext,
  });
  final List<AccessLogEntry> items;
  final String? nextCursor;
  final bool hasNext;
  factory AccessLogPage.fromJson(Map<String, dynamic> json) => AccessLogPage(
    items: (json['items'] as List? ?? const [])
        .map((item) => AccessLogEntry.fromJson(item as Map<String, dynamic>))
        .toList(),
    nextCursor: json['nextCursor'] as String?,
    hasNext: json['hasNext'] as bool? ?? false,
  );
}
