import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

class VideoExportException implements Exception {
  const VideoExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

class VideoEditorExporter {
  static const _channel = MethodChannel('com.williamjames/video_canvas');

  Future<List<String>> generateThumbnails({
    required String inputPath,
    required int count,
  }) async {
    final temporary = await getTemporaryDirectory();
    final outputDirectory = Directory(
      '${temporary.path}${Platform.pathSeparator}thumbnails${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}',
    );
    await outputDirectory.create(recursive: true);

    final controller = VideoPlayerController.file(File(inputPath));
    await controller.initialize();
    final duration = controller.value.duration.inMilliseconds;
    final files = <String>[];
    for (var index = 0; index < count; index++) {
      final targetMs = (duration * index / count).round();
      await controller.seekTo(Duration(milliseconds: targetMs));
      final file = File('${outputDirectory.path}${Platform.pathSeparator}thumb_$index.jpg');
      files.add(file.path);
    }
    await controller.dispose();
    return files;
  }

  Future<String> exportEditedVideo({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
    required double aspectRatio,
  }) async {
    final outputFile = File(outputPath);
    outputFile.parent.createSync(recursive: true);
    if (outputFile.existsSync()) {
      outputFile.deleteSync();
    }

    final result = await _channel.invokeMethod<String>('exportWithTrim', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'endMs': endMs,
      'aspectRatio': aspectRatio,
    });
    if (result == null || result.isEmpty) {
      throw const VideoExportException('영상 저장을 완료하지 못했어요.');
    }
    return result;
  }

  Future<String> saveToGallery({
    required String inputPath,
    required String title,
  }) async {
    final file = File(inputPath);
    if (!await file.exists()) {
      throw const VideoExportException('저장할 영상 파일을 찾지 못했어요.');
    }

    final result = await _channel.invokeMethod<String>('saveToGallery', {
      'inputPath': inputPath,
      'title': title,
    });
    if (result == null || result.isEmpty) {
      throw const VideoExportException('갤러리에 저장하지 못했어요.');
    }
    return result;
  }
}
