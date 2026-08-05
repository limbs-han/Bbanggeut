import 'package:dio/dio.dart';

import '../../core/api_client.dart';
import 'laugh_draw_models.dart';

abstract class LaughDrawRepository {
  /// 최근 [days]일 안에 저장된 우리 가족 웃음 영상 하나를 무작위로 받는다.
  /// [excludeIds]는 이번 화면에서 이미 본 영상이다.
  Future<LaughDrawResult> drawRandom(
    String familyId, {
    int days = 3,
    List<String> excludeIds = const [],
  });

  /// 기기에 적어 둔 "오늘 뽑은 영상"을 서버에서 다시 읽어 화면을 되살린다.
  /// 지워지거나 만료된 영상이면 404([ApiFailure])를 던진다.
  Future<LaughMemory> findMemory(String memoryId);

  /// 이모지 반응을 남기거나 바꾼다. 서버가 계산한 최종 개수를 돌려준다.
  Future<LaughMemory> react(String memoryId, LaughReactionType reaction);
}

class RemoteLaughDrawRepository implements LaughDrawRepository {
  RemoteLaughDrawRepository(ApiClient api) : _dio = api.authenticatedDio;

  final Dio _dio;

  @override
  Future<LaughDrawResult> drawRandom(
    String familyId, {
    int days = 3,
    List<String> excludeIds = const [],
  }) async => LaughDrawResult.fromJson(
    await _map(
      _dio.get<dynamic>(
        '/api/families/$familyId/laugh-memories/random',
        queryParameters: {
          'days': days,
          if (excludeIds.isNotEmpty) 'excludeIds': excludeIds.join(','),
        },
      ),
    ),
  );

  @override
  Future<LaughMemory> findMemory(String memoryId) async => LaughMemory.fromJson(
    await _map(_dio.get<dynamic>('/api/laugh-memories/$memoryId')),
  );

  @override
  Future<LaughMemory> react(
    String memoryId,
    LaughReactionType reaction,
  ) async => LaughMemory.fromJson(
    await _map(
      _dio.put<dynamic>(
        '/api/laugh-memories/$memoryId/reaction',
        data: {'reactionType': reaction.wireName},
      ),
    ),
  );

  /// 기존 [ApiClient]와 같은 실패 모양([ApiFailure])으로 바꿔 준다.
  /// 화면이 상태 코드로 문구를 가르기 때문에 코드도 함께 넘긴다.
  Future<Map<String, dynamic>> _map(Future<Response<dynamic>> call) async {
    try {
      final response = await call;
      final data = response.data;
      if (data is Map) return data.cast<String, dynamic>();
      throw const ApiFailure('서버 응답을 읽지 못했어요.');
    } on DioException catch (error) {
      final data = error.response?.data;
      throw ApiFailure(
        data is Map
            ? data['message'] as String? ?? '요청을 처리하지 못했어요.'
            : error.type == DioExceptionType.connectionError
            ? '서버에 연결할 수 없어요. 네트워크를 확인해 주세요.'
            : '잠시 후 다시 시도해 주세요.',
        code: data is Map ? data['code'] as String? : null,
        statusCode: error.response?.statusCode,
      );
    }
  }
}
