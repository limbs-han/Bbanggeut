import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ve_sdk_flutter/errors.dart';
import 'package:ve_sdk_flutter/export_data.dart';
import 'package:ve_sdk_flutter/export_result.dart';
import 'package:ve_sdk_flutter/features_config.dart';
import 'package:ve_sdk_flutter/ve_sdk_flutter.dart';

class BanubaEditorException implements Exception {
  const BanubaEditorException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SavedBanubaEdit {
  const SavedBanubaEdit({
    required this.videoPath,
    this.coverPath,
    this.metaPath,
  });

  final String videoPath;
  final String? coverPath;
  final String? metaPath;
}

class BanubaVideoEditor {
  BanubaVideoEditor({VeSdkFlutter? sdk}) : _sdk = sdk ?? VeSdkFlutter();

  static const _compiledLicenseToken = String.fromEnvironment(
    'BANUBA_LICENSE_TOKEN',
  );
  static const _localConfigAsset = 'assets/config/banuba.local.json';
  static const _giphyApiKey = String.fromEnvironment('GIPHY_API_KEY');
  static const _aiAudioDataUrl = String.fromEnvironment(
    'BANUBA_AI_AUDIO_DATA_URL',
  );
  static const _aiAudioTracksUrl = String.fromEnvironment(
    'BANUBA_AI_AUDIO_TRACKS_URL',
  );
  static const _captionsApiKey = String.fromEnvironment(
    'BANUBA_CAPTIONS_API_KEY',
    // Banuba's Flutter SDK documents this key for trial AI Captions only.
    defaultValue: 'CheiYaaphoK6eungecheec4eingeik9shaijiech',
  );
  static const _captionsApiV2Key = String.fromEnvironment(
    'BANUBA_CAPTIONS_API_V2_KEY',
  );
  static const _captionsUploadUrl = String.fromEnvironment(
    'BANUBA_CAPTIONS_UPLOAD_URL',
    defaultValue: 'https://internal.transcribe.banuba.net',
  );
  static const _captionsTranscribeUrl = String.fromEnvironment(
    'BANUBA_CAPTIONS_TRANSCRIBE_URL',
    defaultValue:
        'https://rest.internal.transcribe.banuba.net/transcribe/v1/status',
  );
  static const _exportQuality = String.fromEnvironment(
    'BANUBA_EXPORT_QUALITY',
    defaultValue: 'hd720p',
  );
  static const _useHevc = bool.fromEnvironment(
    'BANUBA_USE_HEVC',
    defaultValue: false,
  );

  final VeSdkFlutter _sdk;
  String? _resolvedLicenseToken;

  Future<bool> get isConfigured async =>
      (await _resolveLicenseToken()).isNotEmpty;
  bool get isAiClippingConfigured =>
      _aiAudioDataUrl.isNotEmpty && _aiAudioTracksUrl.isNotEmpty;
  bool get isAiCaptionsConfigured =>
      _captionsApiV2Key.isNotEmpty ||
      (_captionsApiKey.isNotEmpty &&
          _captionsUploadUrl.isNotEmpty &&
          _captionsTranscribeUrl.isNotEmpty);

  Future<SavedBanubaEdit?> edit({
    required List<String> sourcePaths,
    required String outputName,
    bool enableAiCaptions = false,
  }) async {
    final licenseToken = await _requireLicenseToken();
    if (enableAiCaptions && !isAiCaptionsConfigured) {
      throw const BanubaEditorException(
        'AI 자동 자막을 사용하려면 Banuba Captions API 키가 필요해요.',
      );
    }
    try {
      final result = await _sdk.openEditorScreen(
        licenseToken,
        _features(enableAiCaptions: enableAiCaptions),
        sourcePaths,
        exportData: _exportData(outputName),
      );
      return result == null ? null : _saveToAppStorage(result, outputName);
    } on PlatformException catch (error) {
      if (error.code == 'ERR_VIDEO_EXPORT_CANCEL') return null;
      throw BanubaEditorException(_messageFor(error));
    }
  }

  Future<SavedBanubaEdit?> aiClip({required String outputName}) async {
    final licenseToken = await _requireLicenseToken();
    if (!isAiClippingConfigured) {
      throw const BanubaEditorException(
        'AI 자동 편집을 사용하려면 Banuba AI Clipping용 '
        'audioDataUrl과 audioTracksUrl이 필요해요.',
      );
    }
    try {
      final result = await _sdk.openAiClippingScreen(
        licenseToken,
        _features(enableAiClipping: true),
        exportData: _exportData(outputName),
      );
      return result == null ? null : _saveToAppStorage(result, outputName);
    } on PlatformException catch (error) {
      if (error.code == 'ERR_VIDEO_EXPORT_CANCEL') return null;
      throw BanubaEditorException(_messageFor(error));
    }
  }

  Future<SavedBanubaEdit?> aiEdit({
    required List<String> sourcePaths,
    required String outputName,
  }) async {
    final licenseToken = await _requireLicenseToken();
    if (!isAiCaptionsConfigured && !isAiClippingConfigured) {
      throw const BanubaEditorException(
        'Banuba AI 설정이 필요해요. Captions API 또는 AI Clipping URL을 확인해 주세요.',
      );
    }
    try {
      final result = await _sdk.openEditorScreen(
        licenseToken,
        _features(
          enableAiCaptions: isAiCaptionsConfigured,
          enableAiClipping: isAiClippingConfigured,
        ),
        sourcePaths,
        exportData: _exportData(outputName),
      );
      return result == null ? null : _saveToAppStorage(result, outputName);
    } on PlatformException catch (error) {
      if (error.code == 'ERR_VIDEO_EXPORT_CANCEL') return null;
      throw BanubaEditorException(_messageFor(error));
    }
  }

  Future<SavedBanubaEdit?> openDrafts({required String outputName}) async {
    final licenseToken = await _requireLicenseToken();
    try {
      final result = await _sdk.openDraftsScreen(
        licenseToken,
        _features(),
        exportData: _exportData(outputName),
      );
      return result == null ? null : _saveToAppStorage(result, outputName);
    } on PlatformException catch (error) {
      if (error.code == 'ERR_VIDEO_EXPORT_CANCEL') return null;
      throw BanubaEditorException(_messageFor(error));
    }
  }

  FeaturesConfig _features({
    bool enableAiClipping = false,
    bool enableAiCaptions = false,
  }) {
    final builder = FeaturesConfigBuilder()
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
            // Keep the entire landscape event video visible inside the 9:16 canvas.
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
        );

    if (enableAiClipping) {
      builder.setAiClipping(
        const AiClipping(
          audioDataUrl: _aiAudioDataUrl,
          audioTracksUrl: _aiAudioTracksUrl,
        ),
      );
    }
    if (enableAiCaptions) {
      builder.setCaptions(
        const Captions(
          uploadUrl: _captionsUploadUrl,
          transcribeUrl: _captionsTranscribeUrl,
          apiKey: _captionsApiKey,
          apiV2Key: _captionsApiV2Key,
        ),
      );
    }
    if (_giphyApiKey.isNotEmpty) {
      builder.setGifPickerConfig(
        const GifPickerConfig(giphyApiKey: _giphyApiKey),
      );
    }
    return builder.build();
  }

  ExportData _exportData(String outputName) => ExportData(
    exportedVideos: [
      ExportedVideo(
        fileName: outputName,
        videoResolution: _exportQuality == 'auto'
            ? VideoResolution.auto
            : VideoResolution.hd720p,
        useHevcIfPossible: _useHevc,
      ),
    ],
  );

  Future<SavedBanubaEdit> _saveToAppStorage(
    ExportResult result,
    String outputName,
  ) async {
    if (result.videoSources.isEmpty) {
      throw const BanubaEditorException('편집은 완료됐지만 내보낸 영상 파일을 찾지 못했어요.');
    }

    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}edited_videos',
    );
    await directory.create(recursive: true);

    final safeName = outputName.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final videoDestination =
        '${directory.path}${Platform.pathSeparator}${safeName}_$timestamp.mp4';
    await _copyResultFile(result.videoSources.first, videoDestination);

    final coverDestination = await _copyOptional(
      result.previewFilePath,
      '${directory.path}${Platform.pathSeparator}${safeName}_${timestamp}_cover.jpg',
    );
    final metaDestination = await _copyOptional(
      result.metaFilePath,
      '${directory.path}${Platform.pathSeparator}${safeName}_${timestamp}_meta.json',
    );

    return SavedBanubaEdit(
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
      final raw = await rootBundle.loadString(_localConfigAsset);
      final config = jsonDecode(raw);
      if (config is Map<String, dynamic>) {
        final local = (config['BANUBA_LICENSE_TOKEN'] as String? ?? '').trim();
        _resolvedLicenseToken = local;
        return local;
      }
    } catch (_) {
      // A local config is optional; production builds should use dart-define.
    }
    _resolvedLicenseToken = '';
    return '';
  }

  Future<String> _requireLicenseToken() async {
    final token = await _resolveLicenseToken();
    if (token.isEmpty) {
      throw const BanubaEditorException(
        'Banuba 라이선스 토큰이 설정되지 않았어요. '
        '로컬 설정 또는 빌드 환경을 확인해 주세요.',
      );
    }
    return token;
  }

  String _messageFor(PlatformException error) => switch (error.code) {
    errCodeSdkNotInitialized =>
      'Banuba 토큰을 인식하지 못했어요. 토큰이 잘리거나 변형되지 않았는지 확인해 주세요.',
    errCodeSdkLicenseRevoked => 'Banuba 라이선스가 만료되었거나 비활성화됐어요.',
    errCodeMissingHost => '영상 편집 화면을 표시할 Activity를 찾지 못했어요.',
    errCodeInvalidParams => '영상 편집기에 전달한 파일 또는 설정이 올바르지 않아요.',
    errCodeMissingExportResult => '편집 결과 파일을 만들지 못했어요.',
    _ => error.message ?? '영상 편집기를 실행하지 못했어요.',
  };
}
