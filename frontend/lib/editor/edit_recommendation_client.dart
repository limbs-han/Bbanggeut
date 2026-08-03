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

class EditRecommendationClient {
  /// 위젯 테스트에서 화면이 initState에서 이 클라이언트를 부르면 Dio 타이머가
  /// 남아 테스트가 깨진다. flutter test는 FLUTTER_TEST 환경 변수를 세운다 —
  /// 그때는 부르는 쪽이 네트워크를 건너뛴다.
  static bool get networkAllowed =>
      !Platform.environment.containsKey('FLUTTER_TEST');

  EditRecommendationClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: const String.fromEnvironment(
                'EDITOR_API_BASE_URL',
                defaultValue: 'http://127.0.0.1:18080',
              ),
              connectTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );

  final Dio _dio;

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

  /// 완성본 업로드 주소(쿼리 포함). 백그라운드 업로더(WorkManager)가 앱
  /// 밖에서 그대로 PUT한다 — Dart가 살아 있지 않아도 되도록 완성된 URL을
  /// 넘긴다.
  String editedVideoUploadUrl({
    required String videoId,
    String title = '',
    int durationMs = 0,
    DateTime? capturedAt,
  }) => Uri.parse('${_dio.options.baseUrl}/v1/edited-videos/$videoId')
      .replace(
        queryParameters: {
          'title': title,
          'durationMs': '$durationMs',
          // 원본이 감지된(촬영된) 시각 — 캘린더가 이 날짜에 표시한다.
          if (capturedAt != null)
            'capturedAt': capturedAt.toLocal().toIso8601String(),
        },
      )
      .toString();

  /// 편집 완료 영상 목록(메타).
  Future<List<Map<String, dynamic>>> listEditedVideos() async {
    final response = await _dio.get<Map<String, dynamic>>('/v1/edited-videos');
    return [
      for (final item in response.data?['items'] as List? ?? const [])
        Map<String, dynamic>.from(item as Map),
    ];
  }

  /// 편집 영상 재생 주소. video_player에 그대로 넘긴다.
  String editedVideoUrl(String videoId) =>
      '${_dio.options.baseUrl}/v1/edited-videos/$videoId/file';

  /// 편집 완료 영상을 파일로 내려받는다. 갤러리 저장이 쓴다.
  Future<void> downloadEditedVideo(
    String videoId,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) async {
    await _dio.download(
      '/v1/edited-videos/$videoId/file',
      savePath,
      onReceiveProgress: onProgress,
      options: Options(receiveTimeout: const Duration(minutes: 10)),
    );
  }

  Future<List<Map<String, dynamic>>> listComments(String videoId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/edited-videos/$videoId/comments',
    );
    return [
      for (final item in response.data?['items'] as List? ?? const [])
        Map<String, dynamic>.from(item as Map),
    ];
  }

  Future<void> addComment(
    String videoId,
    String text, {
    String author = '가족',
  }) async {
    await _dio.post<void>(
      '/v1/edited-videos/$videoId/comments',
      data: {'author': author, 'text': text},
    );
  }
}
