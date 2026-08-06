import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

typedef CacheDirectoryProvider = Future<Directory> Function();
typedef DownloadProgress = void Function(int received, int total);

/// 편집 화면과 갤러리 저장이 같이 쓰는 원본 영상 캐시.
///
/// 예전에는 두 기능이 같은 영상을 각자 내려받았고, 갤러리 저장은 끝나자마자
/// 받은 파일을 지웠다. 한 곳에 모으면 세 가지가 달라진다.
///
/// 1. 상세 화면에서 미리 받아 두면 편집 진입이 기다림 없이 열린다.
/// 2. 저장한 영상을 이어서 편집하거나, 편집했던 영상을 저장할 때 네트워크가
///    아예 필요 없다.
/// 3. 같은 영상을 두 곳에서 동시에 요청해도 다운로드는 한 번만 돈다.
class VideoSourceCache {
  const VideoSourceCache._();

  /// 남겨 두는 원본 개수와 총 용량. 둘 중 먼저 걸리는 쪽이 기준이다.
  ///
  /// 갤러리 저장이 받은 파일을 지우지 않고 남기게 됐으니 상한이 필요하다.
  /// 임시 디렉터리라 저장 공간이 모자라면 OS도 알아서 비우지만, 그 전에
  /// 우리가 먼저 정리한다.
  static const _maxCachedSources = 8;
  static const _maxCachedBytes = 512 * 1024 * 1024;

  static Directory? _temporaryRoot;
  static final Map<String, _ActiveDownload> _active = {};

  static Future<Directory> _root(CacheDirectoryProvider? provider) async {
    if (provider != null) return provider();
    // getTemporaryDirectory는 플랫폼 채널 왕복이다. 편집 진입마다 다시 물을
    // 이유가 없다.
    return _temporaryRoot ??= await getTemporaryDirectory();
  }

  static String _pathIn(Directory directory, String videoId) =>
      '${directory.path}${Platform.pathSeparator}event-$videoId.mp4';

  /// 이미 통째로 받아 둔 파일의 경로. 없으면 null.
  ///
  /// 받는 도중에는 `.download` 이름을 쓰므로 이 경로에 있는 파일은 언제나
  /// 완성본이다.
  static Future<String?> cachedPath(
    String videoId, {
    CacheDirectoryProvider? cacheDirectoryProvider,
  }) async {
    try {
      final file = File(_pathIn(await _root(cacheDirectoryProvider), videoId));
      if (await file.exists() && await file.length() > 0) return file.path;
    } catch (_) {
      // 캐시를 못 읽는 건 실패가 아니다. 그냥 다시 받으면 된다.
    }
    return null;
  }

  /// 원본이 기기에 있도록 보장하고 그 경로를 준다.
  static Future<String> ensure({
    required ApiClient api,
    required String videoId,
    CacheDirectoryProvider? cacheDirectoryProvider,
    DownloadProgress? onProgress,
  }) async {
    final cached = await cachedPath(
      videoId,
      cacheDirectoryProvider: cacheDirectoryProvider,
    );
    if (cached != null) return cached;

    final running = _active[videoId];
    if (running != null) return running.join(onProgress);

    final download = _ActiveDownload();
    _active[videoId] = download;
    download.future = _download(
      api,
      videoId,
      cacheDirectoryProvider,
      download.report,
    ).whenComplete(() => _active.remove(videoId));
    return download.join(onProgress);
  }

  /// 곧 필요해질 원본을 미리 받아 둔다.
  ///
  /// 상세 화면이 열리면 다음 행동은 대개 편집이거나 갤러리 저장이고, 둘 다
  /// 같은 파일을 필요로 한다. 화면을 보는 동안 미리 받아 두면 버튼을 눌렀을
  /// 때 기다림이 없다. 실패해도 조용히 넘어간다 — 실제로 필요해질 때 다시
  /// 받는다.
  static void prefetch({
    required ApiClient api,
    required String videoId,
    CacheDirectoryProvider? cacheDirectoryProvider,
  }) {
    if (_active.containsKey(videoId)) return;
    unawaited(
      ensure(
        api: api,
        videoId: videoId,
        cacheDirectoryProvider: cacheDirectoryProvider,
      ).catchError((Object _) => ''),
    );
  }

  static Future<String> _download(
    ApiClient api,
    String videoId,
    CacheDirectoryProvider? provider,
    DownloadProgress onProgress,
  ) async {
    final directory = await _root(provider);
    final destination = _pathIn(directory, videoId);
    final partial = File('$destination.download');
    if (await partial.exists()) await partial.delete();

    await api.downloadVideoToFile(
      videoId,
      partial.path,
      onReceiveProgress: onProgress,
    );

    final target = File(destination);
    if (await target.exists()) await target.delete();
    await partial.rename(destination);
    unawaited(_prune(directory, keep: destination));
    return destination;
  }

  /// 캐시가 저장 공간을 계속 먹지 않게 오래된 원본을 정리한다.
  ///
  /// 편집 결과물은 다른 이름으로 저장되므로 여기서 지워지지 않는다.
  static Future<void> _prune(
    Directory directory, {
    required String keep,
  }) async {
    try {
      final sources = <({File file, DateTime modified, int size})>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('event-') || !name.endsWith('.mp4')) continue;
        final stat = await entity.stat();
        sources.add((file: entity, modified: stat.modified, size: stat.size));
      }

      // 최근에 쓴 것부터 남긴다.
      sources.sort((a, b) => b.modified.compareTo(a.modified));
      var keptCount = 0;
      var keptBytes = 0;
      for (final source in sources) {
        final withinBudget =
            keptCount < _maxCachedSources &&
            keptBytes + source.size <= _maxCachedBytes;
        if (withinBudget || source.file.path == keep) {
          keptCount++;
          keptBytes += source.size;
          continue;
        }
        try {
          await source.file.delete();
        } catch (_) {
          // 다른 화면이 쓰고 있을 수 있다. 다음 정리 때 다시 시도한다.
        }
      }
    } catch (_) {
      // 정리는 부가 작업이다. 실패해도 다운로드 결과에는 영향이 없다.
    }
  }
}

/// 돌고 있는 다운로드 하나. 여러 화면이 같은 진행률을 나눠 본다.
class _ActiveDownload {
  final _listeners = <DownloadProgress>[];
  late final Future<String> future;
  int _received = 0;
  int _total = 0;

  void report(int received, int total) {
    _received = received;
    _total = total;
    for (final listener in List.of(_listeners)) {
      listener(received, total);
    }
  }

  Future<String> join(DownloadProgress? onProgress) async {
    if (onProgress == null) return future;
    _listeners.add(onProgress);
    // 뒤늦게 붙은 화면도 지금까지 받은 만큼을 바로 보게 한다.
    if (_total > 0) onProgress(_received, _total);
    try {
      return await future;
    } finally {
      _listeners.remove(onProgress);
    }
  }
}
