import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

const defaultApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://i15e201.p.ssafy.io',
);

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

  bool _isPublicAuthPath(String path) =>
      path.contains('/api/auth/login') ||
      path.contains('/api/auth/signup') ||
      path.contains('/api/auth/refresh');

  Future<bool> get hasSession async {
    _memoryAccessToken = await _storage.read(key: _accessKey);
    _memoryRefreshToken = await _storage.read(key: _refreshKey);
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

  Future<void> logout() async {
    try {
      await _dio.post<void>('/api/auth/logout');
    } finally {
      await clearSession();
    }
  }

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
  Future<DeviceSummary> claimDevice(String registrationCode) async =>
      DeviceSummary.fromJson(
        await _post(
          '/api/devices/claim',
          data: {'registrationCode': registrationCode.trim()},
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
  Future<Invitation> createInvitation(String deviceId, String email) async =>
      Invitation.fromJson(
        await _post(
          '/api/devices/$deviceId/invitations',
          data: {'email': email.trim()},
        ),
      );
  Future<List<Invitation>> listDeviceInvitations(String deviceId) async =>
      (await _getList(
        '/api/devices/$deviceId/invitations',
      )).map(Invitation.fromJson).toList();
  Future<void> revokeInvitation(String deviceId, String invitationId) async =>
      _delete('/api/devices/$deviceId/invitations/$invitationId');
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
  Future<void> transferOwnership(String deviceId, String membershipId) async =>
      _post(
        '/api/devices/$deviceId/transfer-ownership',
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

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    try {
      return ((await _dio.get<List<dynamic>>(path)).data ?? const [])
          .cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  Future<Map<String, dynamic>> _post(String path, {Object? data}) async {
    try {
      final response = await _dio.post<dynamic>(path, data: data);
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
