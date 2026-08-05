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

  /// 영상 길이에 맞춘 안전한 프레임 시점(ms).
  ///
  /// **왜 1분 고정이 안 되는가**: 웃음 감지 영상은 몇 초짜리도 있다. 없는 지점을
  /// 찾으라고 하면 추출이 그냥 실패하고 화면에는 대체 그림만 남는다. 길이의 1/4
  /// 지점을 쓰면 3초 영상은 1초, 13초 영상은 3초, 2분 영상은 30초가 되어 어느
  /// 길이에서도 "영상 중간의 한 장면"이 나온다.
  static int previewTimeMs(int? durationMs) {
    if (durationMs == null || durationMs <= 0) return 1000;
    // 2초 미만은 1초도 넘길 수 있어 비율로만 잡는다.
    if (durationMs <= 2000) return (durationMs * 0.4).round();
    return (durationMs * 0.25).round().clamp(1000, 60000);
  }

  /// 길이에 맞춘 지점에서 뽑은 프레임. 실패하면 null — 부르는 쪽이 영상과 무관한
  /// 그림으로 메우지 않고 중립 자리표시를 그린다.
  ///
  /// [frameAtOneMinute]과 캐시 파일을 나눠 쓴다. 같은 영상에서 서로 다른 지점을
  /// 뽑으므로 한 파일을 공유하면 먼저 만든 쪽 그림이 다른 화면에도 나온다.
  static Future<String?> frameForMemory(ApiClient api, VideoMemory video) {
    final key = '${video.id}#preview';
    final ready = _ready[key];
    if (ready != null) return Future.value(ready);
    return _pending.putIfAbsent(
      key,
      () =>
          _generate(
            api,
            video,
            cacheKey: key,
            fileSuffix: 'preview',
            timeMs: previewTimeMs(video.durationMs),
          ).then((path) {
            // 실패한 시도는 붙잡아 두지 않는다. 재생 URL이 만료됐거나 네트워크가
            // 잠깐 끊긴 것일 수 있어, 다시 뽑았을 때 한 번 더 시도하게 둔다.
            if (path == null) _pending.remove(key);
            return path;
          }),
    );
  }

  /// 길이에 맞춘 지점에서 이미 뽑아 둔 프레임 경로. 없으면 null.
  static String? readyPreviewPath(String videoId) => _ready['$videoId#preview'];

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

  static Future<String?> _generate(
    ApiClient api,
    VideoMemory video, {
    String? cacheKey,
    String fileSuffix = '60s',
    int? timeMs,
  }) async {
    final key = cacheKey ?? video.id;
    try {
      final cacheDirectory = await _cacheDirectory();
      final safeId = video.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final outputPath =
          '${cacheDirectory.path}${Platform.pathSeparator}'
          '${safeId}_$fileSuffix.jpg';
      final cached = File(outputPath);
      // 디스크에 이미 있으면 자리를 기다리지 않는다. 다시 켠 앱에서 목록이
      // 곧바로 채워지는 길이다.
      if (await cached.exists() && await cached.length() > 0) {
        _ready[key] = outputPath;
        return outputPath;
      }

      await _acquire();
      try {
        final signed = await api.createPlayUrl(video.id);
        final durationMs = video.durationMs;
        final targetMs =
            timeMs ??
            (durationMs != null && durationMs < 60000
                ? (durationMs - 500).clamp(0, durationMs)
                : 60000);
        final generated = await VideoThumbnail.thumbnailFile(
          video: signed.url,
          thumbnailPath: outputPath,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 720,
          timeMs: targetMs,
          quality: 82,
        );
        if (generated != null) _ready[key] = generated;
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
