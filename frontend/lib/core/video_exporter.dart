import 'dart:io';

import 'package:flutter/services.dart';

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
    final result = await _channel.invokeListMethod<String>(
      'generateThumbnails',
      {'inputPath': inputPath, 'count': count},
    );
    return result ?? const <String>[];
  }

  Future<String> exportEditedVideo({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
    required double aspectRatio,
    double audioVolume = 1,
    String captionText = '',
    int captionColor = 0xFFFFFFFF,
    String filter = 'none',
    String arSticker = '',
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
      'audioVolume': audioVolume,
      'captionText': captionText,
      'captionColor': captionColor,
      'filter': filter,
      'arSticker': arSticker,
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
