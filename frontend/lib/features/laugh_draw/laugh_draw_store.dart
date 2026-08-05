import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// "오늘 뽑은 추억"을 기기에 적어 두는 곳.
///
/// **왜 저장하는가**: 뽑기는 하루에 한 번 꺼내 보는 재미다. 그런데 커뮤니티 탭을
/// 벗어났다 돌아오거나 앱을 다시 켜면 결과가 사라져, 이미 본 추억을 또 뽑아야
/// 했다. 날짜와 영상 ID만 남겨 두고 다음 진입에서 서버에서 그 영상을 다시 읽어
/// 화면을 되살린다.
///
/// **왜 결과 전체를 저장하지 않는가**: 반응은 가족이 계속 남긴다. 화면을 껍데기째
/// 저장해 두면 다시 열었을 때 어제의 반응 개수가 보인다. 저장은 "무엇을 뽑았는지"
/// 까지만 하고, 제목·반응·가족 반응은 언제나 서버의 최신 값으로 채운다.
class LaughDrawStore {
  LaughDrawStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _dateKey = 'wj_laugh_draw_date';
  static const _videoKey = 'wj_laugh_draw_video_id';

  final FlutterSecureStorage _storage;

  /// 오늘 뽑은 영상 ID. 저장된 날짜가 오늘이 아니면 null — 날이 바뀌면 첫 뽑기
  /// 화면으로 돌아간다.
  Future<String?> todayMemoryId({DateTime? now}) async {
    try {
      final values = await Future.wait([
        _storage.read(key: _dateKey),
        _storage.read(key: _videoKey),
      ]);
      if (values[0] != dayKey(now ?? DateTime.now())) return null;
      final videoId = values[1];
      return videoId == null || videoId.isEmpty ? null : videoId;
    } catch (_) {
      // 저장소를 못 읽어도 첫 뽑기 화면으로는 언제나 들어갈 수 있다.
      return null;
    }
  }

  Future<void> saveToday(String memoryId, {DateTime? now}) async {
    try {
      await Future.wait([
        _storage.write(key: _dateKey, value: dayKey(now ?? DateTime.now())),
        _storage.write(key: _videoKey, value: memoryId),
      ]);
    } catch (_) {
      // 저장 실패는 이번 화면을 못 되살리는 것뿐이라 뽑기를 막지 않는다.
    }
  }

  /// 저장된 영상이 이미 지워지거나 만료됐을 때.
  Future<void> clear() async {
    try {
      await Future.wait([
        _storage.delete(key: _dateKey),
        _storage.delete(key: _videoKey),
      ]);
    } catch (_) {
      // 지우지 못해도 다음 날이면 날짜가 어긋나 스스로 무효가 된다.
    }
  }

  /// 기기 시간대 기준 날짜 키. UTC로 적으면 밤에 뽑은 추억이 자정 전에 사라진다.
  static String dayKey(DateTime now) {
    final local = now.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
