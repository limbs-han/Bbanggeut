DateTime? parseDate(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

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
  bool get isOwner => myRole == 'OWNER';
  factory DeviceSummary.fromJson(Map<String, dynamic> json) => DeviceSummary(
    id: json['id'] as String,
    name: json['name'] as String? ?? '내 카메라',
    model: json['model'] as String? ?? '',
    status: json['status'] as String? ?? 'OFFLINE',
    myRole: json['myRole'] as String? ?? 'MEMBER',
    retentionDays: (json['retentionDays'] as num?)?.toInt() ?? 30,
    lastSeenAt: parseDate(json['lastSeenAt']),
  );
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
    this.sourceType = 'IOT_CAPTURE',
    this.description,
    this.durationMs,
    this.thumbnailUrl,
    this.capturedStartAt,
    this.createdAt,
  });
  final String id;
  final String deviceId;
  final String triggerType;
  final String title;
  final String? description;
  final String status;
  final bool favorite;
  final String sourceType;
  final int? durationMs;
  final String? thumbnailUrl;
  final DateTime? capturedStartAt;
  final DateTime? createdAt;
  factory VideoMemory.fromJson(Map<String, dynamic> json) => VideoMemory(
    id: json['id'] as String,
    deviceId: json['deviceId'] as String,
    triggerType: json['triggerType'] as String? ?? 'MANUAL',
    title: json['title'] as String? ?? '이름 없는 추억',
    description: json['description'] as String?,
    status: json['status'] as String? ?? 'PROCESSING',
    favorite: json['isFavorite'] as bool? ?? false,
    sourceType: json['sourceType'] as String? ?? 'IOT_CAPTURE',
    durationMs: (json['durationMs'] as num?)?.toInt(),
    thumbnailUrl: json['thumbnailUrl'] as String?,
    capturedStartAt: parseDate(json['capturedStartAt']),
    createdAt: parseDate(json['createdAt']),
  );
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
        item['name'] as String: (item['count'] as num).toInt(),
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
    role: json['role'] as String? ?? 'MEMBER',
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
    required this.status,
    this.inviter,
    this.expiresAt,
    this.createdAt,
  });
  final String id;
  final String deviceId;
  final String deviceName;
  final String inviteeEmail;
  final UserSummary? inviter;
  final String status;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  bool get isPending => status == 'PENDING';
  factory Invitation.fromJson(Map<String, dynamic> json) => Invitation(
    id: json['id'] as String? ?? '',
    deviceId: json['deviceId'] as String? ?? '',
    deviceName: json['deviceName'] as String? ?? '카메라',
    inviteeEmail: json['inviteeEmail'] as String? ?? '',
    inviter: json['inviter'] is Map<String, dynamic>
        ? UserSummary.fromJson(json['inviter'] as Map<String, dynamic>)
        : null,
    status: json['status'] as String? ?? 'PENDING',
    expiresAt: parseDate(json['expiresAt']),
    createdAt: parseDate(json['createdAt']),
  );
}

class StreamSession {
  const StreamSession({
    required this.id,
    required this.status,
    required this.heartbeatIntervalSeconds,
    this.playUrl,
    this.viewerExpiresAt,
    this.failureCode,
  });
  final String id;
  final String status;
  final String? playUrl;
  final int heartbeatIntervalSeconds;
  final DateTime? viewerExpiresAt;
  final String? failureCode;
  bool get isReady => status == 'READY' && playUrl != null;
  factory StreamSession.fromJson(Map<String, dynamic> json) => StreamSession(
    id: json['sessionId'] as String,
    status: json['status'] as String? ?? 'PENDING',
    playUrl: json['playUrl'] as String?,
    heartbeatIntervalSeconds:
        (json['heartbeatIntervalSeconds'] as num?)?.toInt() ?? 15,
    viewerExpiresAt: parseDate(json['viewerExpiresAt']),
    failureCode: json['failureCode'] as String?,
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
