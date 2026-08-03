import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'api_client.dart';
import 'models.dart';

class VideoThumbnailCache {
  VideoThumbnailCache._();

  /// 한 번에 돌리는 프레임 추출 개수.
  ///
  /// **왜 막아야 하는가**: 한 장을 뽑는 일은 재생 URL 발급(네트워크 왕복)과
  /// 원격 영상 1분 지점 탐색·디코딩이다. 목록에 스무 개가 걸리면 예전에는
  /// 스무 개가 한꺼번에 시작해 네트워크와 미디어 디코더를 모두 차지했고,
  /// 그 사이 스크롤이 통째로 걸렸다 — "영상 목록이 버벅거린다"의 정체다.
  /// 둘씩만 돌리면 화면이 채워지는 속도는 사실상 같은데(어차피 대역폭이
  /// 한계다) 스크롤은 걸리지 않는다.
  static const _maxConcurrent = 2;

  /// 영상별 추출 작업. 같은 영상을 여러 화면이 그려도 한 번만 돈다.
  static final Map<String, Future<String?>> _pending = {};

  /// 이미 만들어 둔 파일 경로. 스크롤을 되돌렸을 때 기다림도, 원격 썸네일
  /// 대체 이미지의 깜빡임도 없이 바로 그린다.
  static final Map<String, String> _ready = {};

  static final Queue<Completer<void>> _waiting = Queue<Completer<void>>();
  static int _running = 0;

  /// getTemporaryDirectory는 플랫폼 채널 왕복이다. 목록 한 화면에 수십 번
  /// 물을 이유가 없다.
  static Directory? _directory;

  /// 이미 만들어 둔 썸네일 경로. 없으면 null — 기다리지 않는다.
  ///
  /// 첫 프레임부터 진짜 썸네일을 그리는 데 쓴다.
  static String? readyPath(String videoId) => _ready[videoId];

  static Future<String?> frameAtOneMinute(ApiClient api, VideoMemory video) {
    final ready = _ready[video.id];
    if (ready != null) return Future.value(ready);
    return _pending.putIfAbsent(video.id, () => _generate(api, video));
  }

  static Future<Directory> _cacheDirectory() async {
    final cached = _directory;
    if (cached != null) return cached;
    final cacheRoot = await getTemporaryDirectory();
    final directory = Directory(
      '${cacheRoot.path}${Platform.pathSeparator}memory_thumbnails',
    );
    await directory.create(recursive: true);
    return _directory = directory;
  }

  static Future<String?> _generate(ApiClient api, VideoMemory video) async {
    try {
      final cacheDirectory = await _cacheDirectory();
      final safeId = video.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final outputPath =
          '${cacheDirectory.path}${Platform.pathSeparator}${safeId}_60s.jpg';
      final cached = File(outputPath);
      // 디스크에 이미 있으면 자리를 기다리지 않는다. 다시 켠 앱에서 목록이
      // 곧바로 채워지는 길이다.
      if (await cached.exists() && await cached.length() > 0) {
        _ready[video.id] = outputPath;
        return outputPath;
      }

      await _acquire();
      try {
        final signed = await api.createPlayUrl(video.id);
        final durationMs = video.durationMs;
        final targetMs = durationMs != null && durationMs < 60000
            ? (durationMs - 500).clamp(0, durationMs)
            : 60000;
        final generated = await VideoThumbnail.thumbnailFile(
          video: signed.url,
          thumbnailPath: outputPath,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 720,
          timeMs: targetMs,
          quality: 82,
        );
        if (generated != null) _ready[video.id] = generated;
        return generated;
      } finally {
        _release();
      }
    } catch (_) {
      return null;
    }
  }

  static Future<void> _acquire() {
    if (_running < _maxConcurrent) {
      _running++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  static void _release() {
    if (_waiting.isEmpty) {
      _running--;
      return;
    }
    // 자리를 반납하지 않고 그대로 다음 차례에 넘긴다.
    _waiting.removeFirst().complete();
  }
}
