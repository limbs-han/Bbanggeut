import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ve_sdk_flutter/errors.dart';
import 'package:ve_sdk_flutter/export_data.dart';
import 'package:ve_sdk_flutter/export_result.dart';
import 'package:ve_sdk_flutter/features_config.dart';
import 'package:ve_sdk_flutter/ve_sdk_flutter.dart';

import 'saved_video_edit.dart';

class BanubaEditorException implements Exception {
  const BanubaEditorException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BanubaVideoEditor {
  BanubaVideoEditor({VeSdkFlutter? sdk, AssetBundle? assetBundle})
    : _sdk = sdk ?? VeSdkFlutter(),
      _assetBundle = assetBundle ?? rootBundle;

  static const _compiledLicenseToken = String.fromEnvironment(
    'BANUBA_LICENSE_TOKEN',
  );
  static const _localConfigAsset = 'assets/config/banuba.local.json';

  final VeSdkFlutter _sdk;
  final AssetBundle _assetBundle;
  String? _resolvedLicenseToken;

  Future<bool> get isConfigured async =>
      (await _resolveLicenseToken()).isNotEmpty;

  Future<SavedVideoEdit?> edit({
    required List<String> sourcePaths,
    required String outputName,
  }) async {
    if (sourcePaths.isEmpty ||
        sourcePaths.any((path) => !File(path).existsSync())) {
      throw const BanubaEditorException('AR 편집에 사용할 영상 파일을 찾지 못했어요.');
    }
    final licenseToken = await _requireLicenseToken();
    try {
      final result = await _sdk.openEditorScreen(
        licenseToken,
        _features(),
        sourcePaths,
        exportData: _exportData(outputName),
      );
      if (result == null) return null;
      return _saveToAppStorage(result, outputName);
    } on PlatformException catch (error) {
      if (error.code == 'ERR_VIDEO_EXPORT_CANCEL') return null;
      throw BanubaEditorException(_messageFor(error));
    }
  }

  FeaturesConfig _features() => FeaturesConfigBuilder()
      .enableEditorV2(true)
      .setAudioBrowser(AudioBrowser.fromSource(AudioBrowserSource.local))
      .setCameraConfig(
        const CameraConfig(
          supportsBeauty: true,
          supportsColorEffects: true,
          supportsMasks: true,
        ),
      )
      .setEditorConfig(
        const EditorConfig(
          enableVideoAspectFill: false,
          supportsVisualEffects: true,
          supportsColorEffects: true,
          supportsVoiceOver: true,
          supportsAudioEditing: true,
        ),
      )
      .setCoverConfig(const CoverConfig(supportsCoverScreen: true))
      .setDraftsConfig(DraftsConfig.fromOption(DraftsOption.askToSave))
      .setVideoDurationConfig(
        const VideoDurationConfig(
          maxTotalVideoDuration: 600,
          videoDurations: [600],
        ),
      )
      .build();

  ExportData _exportData(String outputName) => ExportData(
    exportedVideos: [
      ExportedVideo(
        fileName: outputName,
        videoResolution: VideoResolution.hd720p,
      ),
    ],
  );

  Future<SavedVideoEdit> _saveToAppStorage(
    ExportResult result,
    String outputName,
  ) async {
    if (result.videoSources.isEmpty) {
      throw const BanubaEditorException('AR 편집 결과 영상 파일을 만들지 못했어요.');
    }

    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}edited_videos',
    );
    await directory.create(recursive: true);

    final safeName = _safeName(outputName);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final videoDestination =
        '${directory.path}${Platform.pathSeparator}'
        '${safeName}_banuba_$timestamp.mp4';
    await _copyResultFile(result.videoSources.first, videoDestination);

    final coverDestination = await _copyOptional(
      result.previewFilePath,
      '${directory.path}${Platform.pathSeparator}'
      '${safeName}_${timestamp}_cover.jpg',
    );
    final metaDestination = await _copyOptional(
      result.metaFilePath,
      '${directory.path}${Platform.pathSeparator}'
      '${safeName}_${timestamp}_meta.json',
    );

    return SavedVideoEdit(
      videoPath: videoDestination,
      coverPath: coverDestination,
      metaPath: metaDestination,
    );
  }

  Future<String?> _copyOptional(String? source, String destination) async {
    if (source == null || source.isEmpty || source == 'null') return null;
    try {
      await _copyResultFile(source, destination);
      return destination;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _copyResultFile(String source, String destination) async {
    final uri = Uri.tryParse(source);
    final sourcePath = uri?.scheme == 'file' ? uri!.toFilePath() : source;
    await File(sourcePath).copy(destination);
  }

  Future<String> _resolveLicenseToken() async {
    final cached = _resolvedLicenseToken;
    if (cached != null) return cached;

    final compiled = _compiledLicenseToken.trim();
    if (compiled.isNotEmpty) {
      _resolvedLicenseToken = compiled;
      return compiled;
    }

    try {
      final raw = await _assetBundle.loadString(_localConfigAsset);
      final config = jsonDecode(raw);
      if (config is Map<String, dynamic>) {
        final local = (config['BANUBA_LICENSE_TOKEN'] as String? ?? '').trim();
        _resolvedLicenseToken = local;
        return local;
      }
    } catch (_) {
      // 로컬 설정은 선택 사항이며 배포 빌드는 dart-define을 사용한다.
    }
    _resolvedLicenseToken = '';
    return '';
  }

  Future<String> _requireLicenseToken() async {
    final token = await _resolveLicenseToken();
    if (token.isEmpty) {
      throw const BanubaEditorException(
        'Banuba 라이선스 토큰이 설정되지 않았어요. '
        '--dart-define 또는 banuba.local.json을 확인해 주세요.',
      );
    }
    return token;
  }

  String _safeName(String value) {
    final safe = value.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    return safe.isEmpty ? 'bbanggeut_edit' : safe;
  }

  String _messageFor(PlatformException error) => switch (error.code) {
    errCodeSdkNotInitialized =>
      'Banuba 토큰을 인식하지 못했어요. Video Editor SDK용 토큰인지 확인해 주세요.',
    errCodeSdkLicenseRevoked => 'Banuba 라이선스가 만료되었거나 비활성화됐어요.',
    errCodeMissingHost => 'Banuba AR 편집 화면을 표시할 Activity를 찾지 못했어요.',
    errCodeInvalidParams => 'Banuba AR 편집기에 전달한 영상이 올바르지 않아요.',
    errCodeMissingExportResult => 'Banuba AR 편집 결과 파일을 만들지 못했어요.',
    _ => error.message ?? 'Banuba AR 편집기를 실행하지 못했어요.',
  };
}
