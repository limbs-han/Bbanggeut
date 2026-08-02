import 'package:dio/dio.dart';

class EditRecommendation {
  const EditRecommendation({
    required this.cutStartMs,
    required this.cutEndMs,
    required this.durationPreset,
    required this.zoomSegments,
  });

  factory EditRecommendation.fromJson(Map<String, dynamic> json) {
    final recipe = Map<String, dynamic>.from(json['recipe'] as Map);
    final cut = Map<String, dynamic>.from(recipe['cut'] as Map);
    final zooms = (recipe['zoomSegments'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    return EditRecommendation(
      cutStartMs: (cut['startMs'] as num).round(),
      cutEndMs: (cut['endMs'] as num).round(),
      durationPreset: recipe['durationPreset'] as String? ?? 'auto',
      zoomSegments: zooms,
    );
  }

  final int cutStartMs;
  final int cutEndMs;
  final String durationPreset;
  final List<Map<String, dynamic>> zoomSegments;
}

class EditRecommendationClient {
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
}
