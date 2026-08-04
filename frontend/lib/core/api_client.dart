import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'fast_downloader.dart';
import 'models.dart';

const defaultApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://i15e201.p.ssafy.io',
);

/// 서버가 Gemini(전사·구성)나 이미지 생성을 부르는 동안 앱이 기다리는 시간.
///
/// 기본 `receiveTimeout` 20초로는 어림도 없다 — 서버는 한 번의 응답 안에서
/// 원본을 객체 저장소에서 꺼내고, 오디오와 대표 프레임을 뽑고, 영상 전체를
/// 멀티모달 모델에 넘긴다. 20초로 두면 서버가 정상으로 일하는 동안 앱이 먼저
/// 끊고 "대사를 알아듣지 못했어요"를 띄운다.
///
/// 서버 예산 150초 + 여유 30초. 이 값을 늘리기 전에 202+폴링으로 계약을 바꾸는
/// 편이 낫다(지금은 범위 밖).
const aiReceiveTimeout = Duration(seconds: 180);

class ApiFailure implements Exception {
  const ApiFailure(
    this.message, {
    this.code,
    this.statusCode,
    this.fieldErrors = const {},
  });
  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, String> fieldErrors;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({Dio? dio, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: defaultApiBaseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {
                'Accept': 'application/json',
                'X-Client-Name': 'william-james-flutter',
              },
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token =
              _memoryAccessToken ?? await _storage.read(key: _accessKey);
          if (token != null && !_isPublicAuthPath(options.path)) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401 &&
              error.requestOptions.extra['retried'] != true &&
              !_isPublicAuthPath(error.requestOptions.path)) {
            final refreshed = await _tryRefresh();
            if (refreshed) {
              final request = error.requestOptions;
              request.extra['retried'] = true;
              request.headers['Authorization'] =
                  'Bearer ${_memoryAccessToken ?? await _storage.read(key: _accessKey)}';
              try {
                return handler.resolve(await _dio.fetch<dynamic>(request));
              } on DioException catch (retryError) {
                return handler.next(retryError);
              }
            }
          }
          handler.next(error);
        },
      ),
    );
  }

  static const _accessKey = 'wj_access_token';
  static const _refreshKey = 'wj_refresh_token';
  static const _userKey = 'wj_user_marker';
  final Dio _dio;
  final FlutterSecureStorage _storage;
  Future<bool>? _refreshFuture;
  String? _memoryAccessToken;
  String? _memoryRefreshToken;
  bool _persistSession = true;

  /// 편집 서버(editor-api)처럼 별도 Dio를 쓰는 클라이언트가 같은 세션으로
  /// 인증하도록 현재 액세스 토큰을 내어 준다. 로그인 전이면 null.
  String? get accessToken => _memoryAccessToken;

  /// 액세스 토큰이 만료됐을 때 외부 클라이언트가 갱신을 부탁하는 통로.
  /// 진행 중인 갱신이 있으면 그 결과를 같이 기다린다.
  Future<bool> refreshAccessToken() => _tryRefresh();

  bool _isPublicAuthPath(String path) =>
      path.contains('/api/auth/login') ||
      path.contains('/api/auth/signup') ||
      path.contains('/api/auth/refresh') ||
      path.contains('/api/auth/password/forgot') ||
      path.contains('/api/auth/password/reset');

  /// 저장된 세션을 읽어 메모리에 올린다.
  ///
  /// 두 열쇠를 나란히 읽는다. 안드로이드 보안 저장소는 읽을 때마다 키스토어를
  /// 거치므로 차례로 읽으면 그 비용이 두 배가 되는데, 이건 앱이 켜질 때 가장
  /// 먼저 하는 일이라 그 시간이 통째로 스플래시에 더해진다.
  Future<bool> get hasSession async {
    final tokens = await Future.wait([
      _storage.read(key: _accessKey),
      _storage.read(key: _refreshKey),
    ]);
    _memoryAccessToken = tokens[0];
    _memoryRefreshToken = tokens[1];
    _persistSession = true;
    return _memoryAccessToken != null;
  }

  Future<UserProfile?> get cachedUser async {
    final raw = await _storage.read(key: _userKey);
    if (raw == null) return null;
    try {
      return UserProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<AuthSession> login(
    String email,
    String password, {
    bool persistSession = true,
  }) async {
    final session = AuthSession.fromJson(
      await _post(
        '/api/auth/login',
        data: {'email': email.trim(), 'password': password},
      ),
    );
    await _saveSession(session, persistSession: persistSession);
    return session;
  }

  Future<AuthSession> signUp(
    String name,
    String email,
    String password, {
    bool persistSession = true,
  }) async {
    final session = AuthSession.fromJson(
      await _post(
        '/api/auth/signup',
        data: {
          'displayName': name.trim(),
          'email': email.trim(),
          'password': password,
        },
      ),
    );
    await _saveSession(session, persistSession: persistSession);
    return session;
  }

  /// 서버는 사용자 열거를 막기 위해 이메일 존재 여부와 무관하게 202를
  /// 반환한다. 재설정 토큰 유효 시간은 30분.
  Future<void> requestPasswordReset(String email) async {
    await _post('/api/auth/password/forgot', data: {'email': email.trim()});
  }

  /// 성공하면 서버가 현재 세션만 남기고 다른 세션을 전부 무효화하므로
  /// 이 기기는 로그인 상태가 유지된다. 새 비밀번호가 기존과 같으면
  /// 422 PASSWORD_UNCHANGED.
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    await _post(
      '/api/auth/password/change',
      data: {'currentPassword': currentPassword, 'newPassword': newPassword},
    );
  }

  Future<void> logout() async {
    try {
      await _dio.post<void>('/api/auth/logout');
    } finally {
      await clearSession();
    }
  }

  Future<List<AppNotification>> listNotifications({int limit = 100}) async =>
      (await _getList(
        '/api/notifications',
        query: {'limit': limit.clamp(1, 100)},
      )).map(AppNotification.fromJson).toList(growable: false);

  Future<int> countUnreadNotifications() async =>
      ((await _get('/api/notifications/unread-count'))['count'] as num?)
          ?.toInt() ??
      0;

  Future<void> markNotificationRead(String notificationId) async =>
      _patch('/api/notifications/$notificationId/read');

  Future<void> markAllNotificationsRead() async =>
      _patch('/api/notifications/read-all');

  Future<void> registerPushToken({
    required String installationId,
    required String token,
    required String platform,
  }) async {
    try {
      await _dio.put<void>(
        '/api/notifications/push-tokens',
        data: {
          'installationId': installationId,
          'token': token,
          'platform': platform,
        },
      );
    } on DioException catch (error) {
      throw _failure(error);
    }
  }

  Future<void> unregisterPushToken(String installationId) async => _delete(
    '/api/notifications/push-tokens/${Uri.encodeComponent(installationId)}',
  );

  Future<NotificationPreferences> getNotificationPreferences() async =>
      NotificationPreferences.fromJson(
        await _get('/api/notifications/preferences'),
      );

  Future<NotificationPreferences> updateNotificationPreferences(
    NotificationPreferences preferences,
  ) async => NotificationPreferences.fromJson(
    await _put('/api/notifications/preferences', data: preferences.toJson()),
  );

  Future<List<CalendarSchedule>> listSchedules() async => (await _getList(
    '/api/schedules',
  )).map(CalendarSchedule.fromJson).toList(growable: false);

  Future<CalendarSchedule> createSchedule(CalendarSchedule schedule) async =>
      CalendarSchedule.fromJson(
        await _post('/api/schedules', data: schedule.toJson()),
      );

  Future<CalendarSchedule> updateSchedule(CalendarSchedule schedule) async =>
      CalendarSchedule.fromJson(
        await _put('/api/schedules/${schedule.id}', data: schedule.toJson()),
      );

  Future<void> deleteSchedule(String scheduleId) async =>
      _delete('/api/schedules/$scheduleId');

  Future<EventStats> getEventStats(
    String deviceId, {
    DateTime? from,
    DateTime? to,
    String? type,
  }) async => EventStats.fromJson(
    await _get(
      '/api/devices/$deviceId/event-stats',
      query: {
        if (from != null) 'from': _dateOnly(from),
        if (to != null) 'to': _dateOnly(to),
        'type': ?type,
      },
    ),
  );

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<UserProfile> updateProfile(String displayName) async {
    final updated = UserProfile.fromJson(
      await _patchMap(
        '/api/auth/me',
        data: {'displayName': displayName.trim()},
      ),
    );
    if (_persistSession) {
      await _storage.write(
        key: _userKey,
        value: jsonEncode({
          'id': updated.id,
          'email': updated.email,
          'displayName': updated.displayName,
        }),
      );
    }
    return updated;
  }

  Future<void> withdraw() async {
    await _dio.delete<void>('/api/auth/me');
    await clearSession();
  }

  Future<void> clearSession() async {
    _memoryAccessToken = null;
    _memoryRefreshToken = null;
    await Future.wait([
      _storage.delete(key: _accessKey),
      _storage.delete(key: _refreshKey),
      _storage.delete(key: _userKey),
    ]);
  }

  Future<List<DeviceSummary>> listDevices() async =>
      (await _getList('/api/devices')).map(DeviceSummary.fromJson).toList();
  Future<List<MemoryVault>> listVaults() async =>
      (await _getList('/api/vaults')).map(MemoryVault.fromJson).toList();
  Future<MemoryVault> createVault(String name) async => MemoryVault.fromJson(
    await _post('/api/vaults', data: {'name': name.trim()}),
  );
  Future<DeviceSummary> claimDevice(
    String registrationCode, {
    String? vaultId,
    String? vaultName,
  }) async => DeviceSummary.fromJson(
    await _post(
      '/api/devices/claim',
      data: {
        'registrationCode': registrationCode.trim(),
        'vaultId': ?vaultId,
        'vaultName': ?vaultName,
      },
    ),
  );
  Future<DeviceStatus> getDeviceStatus(String id) async =>
      DeviceStatus.fromJson(await _get('/api/devices/$id/status'));
  Future<VideoStats> getVideoStats(String id) async =>
      VideoStats.fromJson(await _get('/api/devices/$id/stats'));
  Future<HomeSummary> getHomeSummary(String id) async =>
      HomeSummary.fromJson(await _get('/api/devices/$id/home-summary'));
  Future<VideoPage> listVideos(
    String deviceId, {
    String? triggerType,
    String? cursor,
    DateTime? from,
    DateTime? to,
    int size = 30,
  }) async => VideoPage.fromJson(
    await _get(
      '/api/videos',
      query: {
        'deviceId': deviceId,
        'triggerType': ?triggerType,
        'cursor': ?cursor,
        'from': ?from?.toUtc().toIso8601String(),
        'to': ?to?.toUtc().toIso8601String(),
        'size': size.clamp(1, 100),
      },
    ),
  );
  Future<SignedUrl> createPlayUrl(String id) async =>
      SignedUrl.fromJson(await _post('/api/videos/$id/play-url'));
  Future<SignedUrl> createDownloadUrl(String id) async =>
      SignedUrl.fromJson(await _post('/api/videos/$id/download-url'));
  Future<void> downloadVideoToFile(
    String id,
    String destinationPath, {
    ProgressCallback? onReceiveProgress,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final signed = await createDownloadUrl(id);
      try {
        // MinIO/S3 presigned URLs already contain their own authentication.
        // The API client's Bearer interceptor must not run for this request,
        // so the download goes through its own long-lived client.
        await FastDownloader.download(
          signed.url,
          destinationPath,
          onReceiveProgress: onReceiveProgress,
        );
        return;
      } on DioException catch (error) {
        final statusCode = error.response?.statusCode;
        final signedUrlMayHaveExpired = statusCode == 401 || statusCode == 403;
        if (attempt == 0 && signedUrlMayHaveExpired) {
          continue;
        }
        throw ApiFailure(
          statusCode == null
              ? '영상 다운로드 서버에 연결하지 못했어요.'
              : '영상을 다운로드하지 못했어요. (HTTP $statusCode)',
          code: 'VIDEO_DOWNLOAD_FAILED',
          statusCode: statusCode,
        );
      }
    }
  }

  Future<void> updateVideo(
    String id, {
    String? title,
    String? description,
    bool? favorite,
  }) async => _patch(
    '/api/videos/$id',
    data: {
      'title': ?title,
      'description': ?description,
      'isFavorite': ?favorite,
    },
  );
  Future<void> deleteVideo(String id) async => _delete('/api/videos/$id');
  Future<VideoMemory> getVideo(String id) async =>
      VideoMemory.fromJson(await _get('/api/videos/$id'));
  Future<List<DeviceMember>> listMembers(String deviceId) async =>
      (await _getList(
        '/api/devices/$deviceId/members',
      )).map(DeviceMember.fromJson).toList();
  Future<List<DeviceMember>> listVaultMembers(String vaultId) async =>
      (await _getList(
        '/api/vaults/$vaultId/members',
      )).map(DeviceMember.fromJson).toList();
  Future<DeviceSummary> updateDevice(
    String deviceId, {
    String? name,
    int? retentionDays,
  }) async => DeviceSummary.fromJson(
    await _patchMap(
      '/api/devices/$deviceId',
      data: {'name': ?name, 'retentionDays': ?retentionDays},
    ),
  );
  Future<Invitation> createInvitation(
    String deviceId,
    String email,
    String role, {
    String? membershipRequestToken,
  }) async => Invitation.fromJson(
    await _post(
      '/api/devices/$deviceId/invitations',
      data: {
        'email': email.trim(),
        'role': role,
        'membershipRequestToken': ?membershipRequestToken,
      },
    ),
  );
  Future<Invitation> createVaultInvitation(
    String vaultId,
    String email, {
    String? membershipRequestToken,
  }) async => Invitation.fromJson(
    await _post(
      '/api/vaults/$vaultId/invitations',
      data: {
        'email': email.trim(),
        'role': 'MEMBER',
        'membershipRequestToken': ?membershipRequestToken,
      },
    ),
  );
  Future<MembershipRequestLink> createMembershipRequestLink() async =>
      MembershipRequestLink.fromJson(
        await _post('/api/membership-request-links'),
      );
  Future<MembershipRequestPreview> previewMembershipRequest(
    String token,
  ) async => MembershipRequestPreview.fromJson(
    await _get('/api/membership-request-links/${Uri.encodeComponent(token)}'),
  );
  Future<List<Invitation>> listDeviceInvitations(String deviceId) async =>
      (await _getList(
        '/api/devices/$deviceId/invitations',
      )).map(Invitation.fromJson).toList();
  Future<List<Invitation>> listVaultInvitations(String vaultId) async =>
      (await _getList(
        '/api/vaults/$vaultId/invitations',
      )).map(Invitation.fromJson).toList();
  Future<void> revokeInvitation(String deviceId, String invitationId) async =>
      _delete('/api/devices/$deviceId/invitations/$invitationId');
  Future<void> revokeVaultInvitation(
    String vaultId,
    String invitationId,
  ) async => _delete('/api/vaults/$vaultId/invitations/$invitationId');
  Future<List<Invitation>> listMyInvitations() async =>
      (await _getList('/api/invitations')).map(Invitation.fromJson).toList();
  Future<DeviceMember> acceptInvitation(String invitationId) async =>
      DeviceMember.fromJson(
        await _post('/api/invitations/$invitationId/accept'),
      );
  Future<void> declineInvitation(String invitationId) async =>
      _post('/api/invitations/$invitationId/decline');
  Future<void> revokeMember(String deviceId, String memberId) async =>
      _delete('/api/devices/$deviceId/members/$memberId');
  Future<void> revokeVaultMember(String vaultId, String memberId) async =>
      _delete('/api/vaults/$vaultId/members/$memberId');
  Future<void> transferOwnership(String deviceId, String membershipId) async =>
      _post(
        '/api/devices/$deviceId/transfer-ownership',
        data: {'newOwnerMembershipId': membershipId},
      );
  Future<void> transferVaultOwnership(
    String vaultId,
    String membershipId,
  ) async => _post(
    '/api/vaults/$vaultId/transfer-ownership',
    data: {'newOwnerMembershipId': membershipId},
  );
  Future<void> releaseDevice(String deviceId) async =>
      _delete('/api/devices/$deviceId');
  Future<StreamSession> createStream(String deviceId) async =>
      StreamSession.fromJson(
        await _post('/api/devices/$deviceId/stream-sessions'),
      );
  Future<StreamSession> getStream(String id) async =>
      StreamSession.fromJson(await _get('/api/stream-sessions/$id'));
  Future<void> heartbeatStream(String id) async =>
      _post('/api/stream-sessions/$id/heartbeat');
  Future<void> closeStream(String id) async =>
      _delete('/api/stream-sessions/$id');
  Future<TalkbackSession> openTalkback(String id) async =>
      TalkbackSession.fromJson(
        await _post('/api/stream-sessions/$id/talkback'),
      );
  Future<void> closeTalkback(String id) async =>
      _delete('/api/stream-sessions/$id/talkback');
  Future<SubscriptionInfo> getSubscription(String deviceId) async =>
      SubscriptionInfo.fromJson(
        await _get('/api/devices/$deviceId/subscription'),
      );
  Future<SubscriptionInfo> activateSubscription(String deviceId) async =>
      SubscriptionInfo.fromJson(
        await _put('/api/devices/$deviceId/subscription'),
      );
  Future<SubscriptionInfo> cancelSubscription(String deviceId) async =>
      SubscriptionInfo.fromJson(
        await _deleteMap('/api/devices/$deviceId/subscription'),
      );
  Future<AccessLogPage> listAccessLogPage(
    String deviceId, {
    String? cursor,
    int size = 30,
  }) async => AccessLogPage.fromJson(
    await _get(
      '/api/devices/$deviceId/access-logs',
      query: {'size': size.clamp(1, 100), 'cursor': ?cursor},
    ),
  );

  Future<List<AccessLogEntry>> listAccessLogs(String deviceId) async {
    final result = <AccessLogEntry>[];
    String? cursor;
    do {
      final page = await listAccessLogPage(deviceId, cursor: cursor, size: 100);
      result.addAll(page.items);
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    return result;
  }

  // Subscription and audit logs belong to the vault, so these keep working
  // while the vault has no connected device.
  Future<SubscriptionInfo> getVaultSubscription(String vaultId) async =>
      SubscriptionInfo.fromJson(
        await _get('/api/vaults/$vaultId/subscription'),
      );
  Future<SubscriptionInfo> activateVaultSubscription(String vaultId) async =>
      SubscriptionInfo.fromJson(
        await _put('/api/vaults/$vaultId/subscription'),
      );
  Future<SubscriptionInfo> cancelVaultSubscription(String vaultId) async =>
      SubscriptionInfo.fromJson(
        await _deleteMap('/api/vaults/$vaultId/subscription'),
      );
  Future<AccessLogPage> listVaultAccessLogPage(
    String vaultId, {
    String? cursor,
    int size = 30,
  }) async => AccessLogPage.fromJson(
    await _get(
      '/api/vaults/$vaultId/access-logs',
      query: {'size': size.clamp(1, 100), 'cursor': ?cursor},
    ),
  );

  Future<List<AccessLogEntry>> listVaultAccessLogs(String vaultId) async {
    final result = <AccessLogEntry>[];
    String? cursor;
    do {
      final page = await listVaultAccessLogPage(
        vaultId,
        cursor: cursor,
        size: 100,
      );
      result.addAll(page.items);
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    return result;
  }

  Future<List<VideoMemory>> listAllVideos(
    String deviceId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async {
    final result = <VideoMemory>[];
    String? cursor;
    do {
      final page = await listVideos(
        deviceId,
        triggerType: triggerType,
        cursor: cursor,
        from: from,
        to: to,
        size: 100,
      );
      result.addAll(page.items);
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    return result;
  }

  Future<List<VideoMemory>> listAllVaultVideos(
    String vaultId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async {
    final result = <VideoMemory>[];
    String? cursor;
    do {
      final page = VideoPage.fromJson(
        await _get(
          '/api/videos',
          query: {
            'vaultId': vaultId,
            'triggerType': ?triggerType,
            'cursor': ?cursor,
            'from': ?from?.toUtc().toIso8601String(),
            'to': ?to?.toUtc().toIso8601String(),
            'size': 100,
          },
        ),
      );
      result.addAll(page.items);
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    return result;
  }

  Future<void> _saveSession(AuthSession session, {bool? persistSession}) async {
    if (persistSession != null) _persistSession = persistSession;
    _memoryAccessToken = session.accessToken;
    _memoryRefreshToken = session.refreshToken;
    if (!_persistSession) {
      await Future.wait([
        _storage.delete(key: _accessKey),
        _storage.delete(key: _refreshKey),
        _storage.delete(key: _userKey),
      ]);
      return;
    }
    await Future.wait([
      _storage.write(key: _accessKey, value: session.accessToken),
      _storage.write(key: _refreshKey, value: session.refreshToken),
      _storage.write(
        key: _userKey,
        value: jsonEncode({
          'id': session.user.id,
          'email': session.user.email,
          'displayName': session.user.displayName,
        }),
      ),
    ]);
  }

  Future<bool> _tryRefresh() async {
    final active = _refreshFuture;
    if (active != null) return active;
    final future = _performRefresh();
    _refreshFuture = future;
    try {
      return await future;
    } finally {
      _refreshFuture = null;
    }
  }

  Future<bool> _performRefresh() async {
    final refresh =
        _memoryRefreshToken ?? await _storage.read(key: _refreshKey);
    if (refresh == null) return false;
    try {
      final response = await Dio(BaseOptions(baseUrl: _dio.options.baseUrl))
          .post<Map<String, dynamic>>(
            '/api/auth/refresh',
            data: {'refreshToken': refresh},
          );
      final session = AuthSession.fromJson(response.data!);
      await _saveSession(session);
      return true;
    } catch (_) {
      await clearSession();
      return false;
    }
  }

  /// 전사문으로 4컷 구성을 받는다. 서버가 키를 들고 LLM을 대신 부른다.
  ///
  /// **글만 보낸다** — 영상·오디오·프레임은 보내지 않는다.
  Future<Map<String, dynamic>> createComicScript(
    String videoId,
    List<Map<String, Object>> lines,
  ) => _post(
    '/api/videos/$videoId/comic/script',
    data: {'lines': lines},
    options: _aiOptions,
  );

  /// 4컷 구성으로 만화 그림 한 장(2x2 격자)을 받는다. 응답은 base64 PNG다.
  Future<Map<String, dynamic>> createComicImage(
    String videoId, {
    required List<Map<String, Object?>> cuts,
    required String style,
  }) => _post(
    '/api/videos/$videoId/comic/image',
    data: {'cuts': cuts, 'style': style},
    options: _aiOptions,
  );

  /// 만화 두 엔드포인트(API-71·72)에만 붙이는 긴 수신 대기. 나머지 호출은
  /// 전역 기본값 20초 그대로다 — 평범한 요청까지 3분을 기다리면 안 된다.
  static final _aiOptions = Options(receiveTimeout: aiReceiveTimeout);

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      return (await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: query,
      )).data!;
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<List<Map<String, dynamic>>> _getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      return ((await _dio.get<List<dynamic>>(
                path,
                queryParameters: query,
              )).data ??
              const [])
          .cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    Object? data,
    Options? options,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: data,
        options: options,
      );
      return response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<void> _patch(String path, {Object? data}) async {
    try {
      await _dio.patch<void>(path, data: data);
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<Map<String, dynamic>> _patchMap(String path, {Object? data}) async {
    try {
      return (await _dio.patch<Map<String, dynamic>>(path, data: data)).data!;
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<Map<String, dynamic>> _put(String path, {Object? data}) async {
    try {
      return (await _dio.put<Map<String, dynamic>>(path, data: data)).data!;
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<Map<String, dynamic>> _deleteMap(String path) async {
    try {
      return (await _dio.delete<Map<String, dynamic>>(path)).data!;
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<void> _delete(String path) async {
    try {
      await _dio.delete<void>(path);
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  ApiFailure _failure(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      return ApiFailure(
        data['message'] as String? ?? '요청을 처리하지 못했어요.',
        code: data['code'] as String?,
        statusCode: error.response?.statusCode,
        fieldErrors:
            (data['fieldErrors'] as Map?)?.map(
              (key, value) => MapEntry('$key', '$value'),
            ) ??
            const {},
      );
    }
    return ApiFailure(
      error.type == DioExceptionType.connectionError
          ? '서버에 연결할 수 없어요. 네트워크를 확인해 주세요.'
          : '잠시 후 다시 시도해 주세요.',
      statusCode: error.response?.statusCode,
    );
  }
}
