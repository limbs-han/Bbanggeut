import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'editor_project.dart';

class EditorPlatformException implements Exception {
  const EditorPlatformException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EditorMediaMetadata {
  const EditorMediaMetadata({
    required this.durationMs,
    required this.width,
    required this.height,
    required this.rotationDegrees,
  });

  factory EditorMediaMetadata.fromMap(Map<Object?, Object?> map) =>
      EditorMediaMetadata(
        durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
        rotationDegrees: (map['rotationDegrees'] as num?)?.toInt() ?? 0,
      );

  final int durationMs;
  final int width;
  final int height;
  final int rotationDegrees;
}

class EditorPlatform {
  const EditorPlatform();

  static const _channel = MethodChannel('com.williamjames/video_canvas');

  Future<EditorMediaMetadata> loadMediaMetadata(String inputPath) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'loadMediaMetadata',
      {'inputPath': inputPath},
    );
    if (result == null) {
      throw const EditorPlatformException('영상 정보를 읽지 못했어요.');
    }
    return EditorMediaMetadata.fromMap(result);
  }

  Future<List<String>> generateThumbnails({
    required String inputPath,
    required int count,
  }) async {
    final result = await _channel.invokeListMethod<String>(
      'generateThumbnails',
      {'inputPath': inputPath, 'count': count},
    );
    return result ?? const [];
  }

  Future<String> exportProject({
    required EditorProject project,
    required String outputPath,
    List<Map<String, Object>> captions = const [],
  }) async {
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    if (await output.exists()) await output.delete();
    try {
      final result = await _channel.invokeMethod<String>(
        'exportProject',
        project.toPlatformMap(outputPath: outputPath, captions: captions),
      );
      if (result == null || result.isEmpty) {
        throw const EditorPlatformException('영상 저장을 완료하지 못했어요.');
      }
      return result;
    } on PlatformException catch (failure) {
      throw EditorPlatformException(failure.message ?? '영상 내보내기에 실패했어요.');
    }
  }

  Future<double> getExportProgress() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'getExportProgress',
    );
    return ((result?['progress'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
  }

  Future<void> cancelExport() => _channel.invokeMethod<void>('cancelExport');

  Future<String> saveToGallery({
    required String inputPath,
    required String title,
  }) async {
    final result = await _channel.invokeMethod<String>('saveToGallery', {
      'inputPath': inputPath,
      'title': title,
    });
    if (result == null || result.isEmpty) {
      throw const EditorPlatformException('갤러리에 저장하지 못했어요.');
    }
    return result;
  }
}
