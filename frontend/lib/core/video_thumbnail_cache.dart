import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'api_client.dart';
import 'models.dart';

class VideoThumbnailCache {
  VideoThumbnailCache._();

  static final Map<String, Future<String?>> _pending = {};

  static Future<String?> frameAtOneMinute(ApiClient api, VideoMemory video) =>
      _pending.putIfAbsent(video.id, () => _generate(api, video));

  static Future<String?> _generate(ApiClient api, VideoMemory video) async {
    try {
      final cacheRoot = await getTemporaryDirectory();
      final cacheDirectory = Directory(
        '${cacheRoot.path}${Platform.pathSeparator}memory_thumbnails',
      );
      await cacheDirectory.create(recursive: true);
      final safeId = video.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final outputPath =
          '${cacheDirectory.path}${Platform.pathSeparator}${safeId}_60s.jpg';
      final cached = File(outputPath);
      if (await cached.exists() && await cached.length() > 0) {
        return outputPath;
      }

      final signed = await api.createPlayUrl(video.id);
      final durationMs = video.durationMs;
      final targetMs = durationMs != null && durationMs < 60000
          ? (durationMs - 500).clamp(0, durationMs)
          : 60000;
      return await VideoThumbnail.thumbnailFile(
        video: signed.url,
        thumbnailPath: outputPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 720,
        timeMs: targetMs,
        quality: 82,
      );
    } catch (_) {
      return null;
    }
  }
}
