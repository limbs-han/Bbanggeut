import 'dart:convert';

import 'package:flutter/services.dart';

/// Banuba 라이선스 토큰을 대는 곳.
///
/// **이제 이 클래스가 하는 일은 토큰 공급 하나뿐이다.** 예전에는 여기서
/// `ve_sdk_flutter`의 편집기 화면(`openEditorScreen`)을 열고, 돌아온 결과
/// 영상을 앱 저장소로 복사해 편집기의 새 원본으로 갈아 끼웠다. 앱을 벗어나
/// UI/UX가 통째로 바뀌는 데다, 돌아온 영상에는 자막까지 구워져 있어서 우리
/// 편집 내용과 겹쳤다.
///
/// 지금은 AR 탭이 우리 화면 안에서 엔진을 직접 부른다(`banuba_mask_channel.dart`).
/// 그 다리와 저장할 때 마스크를 굽는 쪽 둘 다 토큰이 필요해서, 토큰을 어디서
/// 읽는지만 여기 한 곳에 남겼다 — dart-define이 먼저고, 없으면
/// `banuba.local.json`이다.
///
/// **`ve_sdk_flutter` 의존성 자체는 빼면 안 된다.** Banuba 네이티브 모듈과
/// nexus 저장소를 그 플러그인이 끌어온다. Dart 쪽에서 부르지 않을 뿐이다.
class BanubaVideoEditor {
  BanubaVideoEditor({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  static const _compiledLicenseToken = String.fromEnvironment(
    'BANUBA_LICENSE_TOKEN',
  );
  static const _localConfigAsset = 'assets/config/banuba.local.json';

  final AssetBundle _assetBundle;
  String? _resolvedLicenseToken;

  Future<bool> get isConfigured async =>
      (await _resolveLicenseToken()).isNotEmpty;

  /// 네이티브 마스크 다리에 넘길 토큰. 없으면 빈 문자열이고, 그때 네이티브가
  /// "토큰이 없어요"로 답한다.
  Future<String> get licenseToken => _resolveLicenseToken();

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
}
