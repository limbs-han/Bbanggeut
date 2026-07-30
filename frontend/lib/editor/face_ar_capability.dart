import 'dart:convert';

import 'package:flutter/services.dart';

class FaceArCapability {
  FaceArCapability({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  static const _compiledLicenseToken = String.fromEnvironment(
    'BANUBA_LICENSE_TOKEN',
  );
  static const _localConfigAsset = 'assets/config/banuba.local.json';

  final AssetBundle _assetBundle;
  String? _resolvedLicenseToken;

  Future<bool> get isConfigured async =>
      (await resolveLicenseToken()).isNotEmpty;

  /// banuba_sdk 3.1.5의 공개 Pigeon API는 카메라·정지 이미지 입력만 제공한다.
  /// 로컬 동영상 프레임 입력과 파일 렌더링 API가 추가되기 전에는 false다.
  bool get supportsLocalVideoRendering => false;

  Future<String> resolveLicenseToken() async {
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
      // 로컬 설정은 선택 사항이며 운영 빌드는 dart-define을 사용한다.
    }
    _resolvedLicenseToken = '';
    return '';
  }
}
