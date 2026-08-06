import 'dart:io';

import 'package:dio/dio.dart';

class EditRecommendation {
  const EditRecommendation({
    required this.cutStartMs,
    required this.cutEndMs,
    required this.durationPreset,
    required this.zoomSegments,
    this.scoreTimeline = const [],
    this.faceTrack = const [],
    this.faceTracks = const [],
  });

  factory EditRecommendation.fromJson(Map<String, dynamic> json) {
    final recipe = Map<String, dynamic>.from(json['recipe'] as Map);
    final cut = Map<String, dynamic>.from(recipe['cut'] as Map);
    final zooms = (recipe['zoomSegments'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    final timeline = (recipe['scoreTimeline'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    final faces = (recipe['faceTrack'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    final faceTracks = (recipe['faceTracks'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    return EditRecommendation(
      cutStartMs: (cut['startMs'] as num).round(),
      cutEndMs: (cut['endMs'] as num).round(),
      durationPreset: recipe['durationPreset'] as String? ?? 'auto',
      zoomSegments: zooms,
      scoreTimeline: timeline,
      faceTrack: faces,
      faceTracks: faceTracks,
    );
  }

  final int cutStartMs;
  final int cutEndMs;
  final String durationPreset;
  final List<Map<String, dynamic>> zoomSegments;

  /// 1초 단위 멀티모달 사건 점수(adaptive_selector.build_timeline 결과).
  /// 웃음·말소리·음량 상승·모션·얼굴 특징을 융합한 `eventScore`가 들어 있다.
  /// 컷 선택이 이 점수를 그대로 쓴다 — 앱에서 점수를 다시 지어내지 않는다.
  final List<Map<String, dynamic>> scoreTimeline;

  /// MediaPipe 표정 분석이 뽑은 얼굴 궤적({ms, x, y, h}, 원본 시각 기준).
  /// 얼굴을 따라다니는 AR 스티커가 쓴다. 옛 서버 호환용 한 줄 궤적이다.
  final List<Map<String, dynamic>> faceTrack;

  /// 사람별 얼굴 궤적({id, samples}). 여러 명이 나오는 영상에서 스티커가
  /// "누구"를 따라갈지 고를 수 있게 한다.
  final List<Map<String, dynamic>> faceTracks;
}

/// 서버 분석 작업 상태. `none`(분석한 적 없음) → `running` → `done`/`failed`.
class EditAnalysisStatus {
  const EditAnalysisStatus({
    required this.status,
    this.progress = 0,
    this.stage,
    this.error,
  });

  factory EditAnalysisStatus.fromJson(Map<String, dynamic> json) =>
      EditAnalysisStatus(
        status: json['status'] as String? ?? 'none',
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        stage: json['stage'] as String?,
        error: json['error'] as String?,
      );

  final String status;
  final double progress;
  final String? stage;
  final String? error;

  bool get isDone => status == 'done';
  bool get isRunning => status == 'running';
  bool get isFailed => status == 'failed';
}

class EditRecommendationClient {
  /// 위젯 테스트에서 화면이 initState에서 이 클라이언트를 부르면 Dio 타이머가
  /// 남아 테스트가 깨진다. flutter test는 FLUTTER_TEST 환경 변수를 세운다 —
  /// 그때는 부르는 쪽이 네트워크를 건너뛴다.
  static bool get networkAllowed =>
      !Platform.environment.containsKey('FLUTTER_TEST');

  /// 실서버 editor-api는 백엔드 액세스 토큰을 요구한다. 화면마다 이
  /// 클라이언트를 새로 만들기 때문에 세션은 앱이 켜질 때 한 번 전역으로
  /// 주입한다(AppController 생성자). null이면 헤더를 붙이지 않는다 —
  /// 로컬 개발 editor-api는 인증이 꺼져 있어 그대로 동작한다.
  static String? Function()? sessionToken;
  static Future<bool> Function()? sessionRefresh;

  EditRecommendationClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: const String.fromEnvironment(
                'EDITOR_API_BASE_URL',
                defaultValue: 'https://i15e201.p.ssafy.io/editor',
              ),
              connectTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 20),
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = sessionToken?.call();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          final refresh = sessionRefresh;
          // 본문이 스트림(파일 업로드)이면 이미 소비돼 재전송할 수 없다.
          if (refresh != null &&
              error.response?.statusCode == 401 &&
              error.requestOptions.extra['retried'] != true &&
              error.requestOptions.data is! Stream) {
            var refreshed = false;
            try {
              refreshed = await refresh();
            } catch (_) {}
            if (refreshed) {
              final request = error.requestOptions;
              request.extra['retried'] = true;
              final token = sessionToken?.call();
              if (token != null) {
                request.headers['Authorization'] = 'Bearer $token';
              }
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

  final Dio _dio;

  /// Dio를 거치지 않는 요청(분석 원본 업로드 등)에 붙일 인증 헤더.
  Map<String, String> get authHeaders {
    final token = sessionToken?.call();
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  Future<EditRecommendation> recommend({
    required String videoId,
    required DateTime? capturedAt,
    bool zoomEnabled = true,
    String? durationPreset,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/edit-recommendations',
      data: <String, Object?>{
        'videoId': videoId,
        // 서버 fixture와 촬영 시각은 현장 로컬 시각(KST) 기준이다. API 응답을
        // UTC로 파싱했더라도 휴대폰 로컬 시각으로 되돌려 보낸다.
        'capturedAt': capturedAt?.toLocal().toIso8601String(),
        'zoomEnabled': zoomEnabled,
        'durationPreset': ?durationPreset,
      },
    );
    return EditRecommendation.fromJson(response.data!);
  }

  /// recommend가 이 실패로 끝났으면 서버는 살아 있지만 이 영상의 분석
  /// 결과가 아직 없다는 뜻이다 — 원본을 올려 분석을 시작하면 된다.
  /// (연결 자체가 안 되는 실패는 response가 없어서 여기 걸리지 않는다.)
  static bool isAnalysisRequired(Object failure) =>
      failure is DioException && failure.response?.statusCode == 404;

  /// 분석 대기 줄이 가득 차 거절당했다(429).
  ///
  /// 실패가 아니라 **나중에 다시 오라**는 뜻이다. 서버는 작업자가 하나뿐이라
  /// 줄을 무한정 받지 않는다 — 받아 두면 차례가 올 때쯤 원본 서명 URL이
  /// 만료되어, 오래 기다린 끝에 실패한다. 화면이 이것을 실패로 알리면
  /// 사용자는 될 일을 안 된다고 믿고 그만둔다.
  static bool isAnalysisBusy(Object failure) =>
      failure is DioException && failure.response?.statusCode == 429;

  /// 백그라운드 분석을 시작한다. 이미 분석돼 있으면 서버가 곧바로 done을
  /// 돌려준다.
  ///
  /// [sourceUrl]이 있으면 서버가 그 주소(백엔드 presigned URL)에서 원본을
  /// 직접 내려받는다 — 실서버에서는 원본이 이미 같은 호스트의 MinIO에
  /// 있으므로 폰이 영상을 LTE로 다시 올리는 낭비를 피한다. 없으면
  /// [filePath]의 로컬 원본을 통째로 올린다.
  ///
  /// [filePath]가 null이면 [sourceUrl]로만 요청한다 — 원본을 아직 내려받지
  /// 않은 시점에 분석을 미리 시작하는 경로다(편집 화면 진입 즉시).
  Future<EditAnalysisStatus> requestAnalysis({
    required String videoId,
    String? filePath,
    String? sourceUrl,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (sourceUrl == null && filePath == null) {
      throw ArgumentError('sourceUrl이나 filePath 하나는 있어야 합니다.');
    }
    final Response<Map<String, dynamic>> response;
    if (sourceUrl != null) {
      response = await _dio.put<Map<String, dynamic>>(
        '/v1/edit-analyses/$videoId',
        data: {'sourceUrl': sourceUrl},
      );
    } else {
      final file = File(filePath!);
      final length = await file.length();
      response = await _dio.put<Map<String, dynamic>>(
        '/v1/edit-analyses/$videoId',
        data: file.openRead(),
        options: Options(
          headers: {Headers.contentLengthHeader: length},
          contentType: 'video/mp4',
          sendTimeout: const Duration(minutes: 5),
        ),
        onSendProgress: onProgress,
      );
    }
    return EditAnalysisStatus.fromJson(response.data!);
  }

  Future<EditAnalysisStatus> analysisStatus(String videoId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/edit-analyses/$videoId',
    );
    return EditAnalysisStatus.fromJson(response.data!);
  }

  Future<void> saveProject({
    required String videoId,
    required int revision,
    required Map<String, Object?> recipe,
  }) async {
    await _dio.put<void>(
      '/v1/edit-projects/$videoId',
      data: <String, Object?>{'revision': revision, 'recipe': recipe},
    );
  }

  /// 저장해 둔 편집 초안. 없으면 null — 그때는 자동 추천으로 연다.
  Future<Map<String, dynamic>?> loadDraft(String videoId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/v1/edit-projects/$videoId',
      );
      return response.data;
    } on DioException catch (failure) {
      if (failure.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 편집 중인(초안이 저장된) 영상 목록.
  Future<List<Map<String, dynamic>>> listDrafts() async {
    final response = await _dio.get<Map<String, dynamic>>('/v1/edit-projects');
    return [
      for (final item in response.data?['items'] as List? ?? const [])
        Map<String, dynamic>.from(item as Map),
    ];
  }

  /// 저장해 둔 초안을 버린다. 없는 초안을 지우라고 해도 성공이다 — 사용자가
  /// 원한 상태(초안 없음)가 이미 이뤄진 것이라 오류로 볼 이유가 없다.
  Future<void> deleteDraft(String videoId) async {
    await _dio.delete<void>('/v1/edit-projects/$videoId');
  }

  /// 서버에 저장된 전사문(AI 자막). 없으면 null.
  ///
  /// **왜 서버에 두는가**: 전사는 폰에만 캐시됐다. 그래서 같은 영상을 가족 각자가
  /// 자기 폰에서 다시 돌렸고(같은 결과에 같은 시간), 앱을 다시 깔면 전부
  /// 날아갔다. 결과는 영상에만 달린 값이라 한 번 만들면 모두가 쓸 수 있다.
  Future<List<Map<String, dynamic>>?> loadTranscript(String videoId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/v1/transcripts/$videoId',
      );
      final lines = response.data?['lines'] as List?;
      if (lines == null || lines.isEmpty) return null;
      return [for (final line in lines) Map<String, dynamic>.from(line as Map)];
    } on DioException catch (failure) {
      if (failure.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 전사문을 서버에 남긴다. 빈 목록은 서버가 거절한다(422).
  Future<void> saveTranscript(
    String videoId,
    List<Map<String, Object?>> lines,
  ) async {
    await _dio.put<void>(
      '/v1/transcripts/$videoId',
      data: <String, Object?>{'lines': lines},
    );
  }
}
