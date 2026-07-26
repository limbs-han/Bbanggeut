import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class PortraitVideoCanvasException implements Exception {
  const PortraitVideoCanvasException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PortraitVideoCanvas {
  static const _channel = MethodChannel('com.williamjames/video_canvas');

  Future<String> fitToNineBySixteen({
    required String inputPath,
    required String outputName,
  }) async {
    if (!Platform.isAndroid) {
      throw const PortraitVideoCanvasException(
        '9:16 AI 영상 자동 생성은 현재 Android에서 사용할 수 있어요.',
      );
    }

    final temporary = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath =
        '${temporary.path}${Platform.pathSeparator}'
        '${outputName}_9x16_$timestamp.mp4';

    try {
      final result = await _channel.invokeMethod<String>('fitToPortrait', {
        'inputPath': inputPath,
        'outputPath': outputPath,
      });
      if (result == null || result.isEmpty) {
        throw const PortraitVideoCanvasException('9:16 영상을 생성하지 못했어요.');
      }
      return result;
    } on PlatformException catch (error) {
      throw PortraitVideoCanvasException(
        error.message ?? '9:16 영상을 생성하지 못했어요.',
      );
    }
  }
}
