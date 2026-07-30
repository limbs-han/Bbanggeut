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
    triggerType: normalizeVideoTrigger(
      json['triggerType'] ?? json['eventType'] ?? json['category'],
    ),
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
