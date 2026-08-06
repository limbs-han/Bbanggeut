import 'dart:io';

import 'package:gal/gal.dart';

import '../editor/editor_platform.dart';
import 'api_client.dart';
import 'video_source_cache.dart';

class VideoGallerySaver {
  const VideoGallerySaver._();

  static const _platform = EditorPlatform();

  static Future<void> save({
    required ApiClient api,
    required String videoId,
    String? title,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const VideoGallerySaveFailure('이 기기에서는 갤러리 저장을 지원하지 않아요.');
    }

    // 내려받기를 먼저 걸고 권한을 확인한다. 예전에는 권한 왕복이 끝나야 첫
    // 바이트를 받기 시작해서, 권한이 이미 있는 기기에서도 그만큼 늦게 끝났다.
    final source = VideoSourceCache.ensure(
      api: api,
      videoId: videoId,
      onProgress: onProgress,
    );
    final access = _requestAccess();

    try {
      final path = await source;
      final granted = await access;
      // 안드로이드 10부터는 내 앱이 만든 영상을 MediaStore에 넣는 데 권한이
      // 필요 없다. 거절된 권한 하나 때문에 저장 전체가 막히지 않게 한다.
      if (!granted && Platform.isIOS) {
        throw const VideoGallerySaveFailure(
          '사진 및 동영상 저장 권한이 필요해요. 기기 설정에서 권한을 허용해 주세요.',
        );
      }
      await _putInGallery(path, title ?? videoId);
    } on GalException catch (error) {
      throw VideoGallerySaveFailure(error.type.message);
    } on ApiFailure catch (error) {
      throw VideoGallerySaveFailure(error.message);
    } on VideoGallerySaveFailure {
      rethrow;
    } catch (error) {
      throw VideoGallerySaveFailure('영상을 저장하지 못했어요. $error');
    }
  }

  static Future<bool> _requestAccess() async {
    try {
      if (await Gal.hasAccess()) return true;
      await Gal.requestAccess();
      return Gal.hasAccess();
    } catch (_) {
      // 권한 확인 자체가 실패하는 기기도 있다. 저장은 그대로 시도한다.
      return false;
    }
  }

  static Future<void> _putInGallery(String path, String title) async {
    if (Platform.isAndroid) {
      try {
        // 네이티브 MediaStore 경로가 gal보다 빠르다 — 커널 복사로 한 번에
        // 옮기고, 권한 플러그인을 거치지 않는다.
        await _platform.saveToGallery(
          inputPath: path,
          title: _safeTitle(title),
        );
        return;
      } on EditorPlatformException {
        // MediaStore가 막힌 기기가 있다. gal로 한 번 더 시도한다.
      }
    }
    await Gal.putVideo(path, album: '빵긋');
  }

  static String _safeTitle(String raw) {
    final value = raw.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    return value.isEmpty ? 'bbanggeut_video' : value;
  }
}

class VideoGallerySaveFailure implements Exception {
  const VideoGallerySaveFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
