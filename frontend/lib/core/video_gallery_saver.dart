import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

class VideoGallerySaver {
  const VideoGallerySaver._();

  static Future<void> save({
    required ApiClient api,
    required String videoId,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const VideoGallerySaveFailure('이 기기에서는 갤러리 저장을 지원하지 않아요.');
    }

    var hasAccess = await Gal.hasAccess();
    if (!hasAccess) {
      await Gal.requestAccess();
      hasAccess = await Gal.hasAccess();
    }
    if (!hasAccess) {
      throw const VideoGallerySaveFailure(
        '사진 및 동영상 저장 권한이 필요해요. 기기 설정에서 권한을 허용해 주세요.',
      );
    }

    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}bbanggeut_$videoId.mp4',
    );
    try {
      await api.downloadVideoToFile(
        videoId,
        file.path,
        onReceiveProgress: onProgress,
      );
      await Gal.putVideo(file.path);
    } on GalException catch (error) {
      throw VideoGallerySaveFailure(error.type.message);
    } on ApiFailure catch (error) {
      throw VideoGallerySaveFailure(error.message);
    } on VideoGallerySaveFailure {
      rethrow;
    } catch (error) {
      throw VideoGallerySaveFailure('영상을 저장하지 못했어요. $error');
    } finally {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }
}

class VideoGallerySaveFailure implements Exception {
  const VideoGallerySaveFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
