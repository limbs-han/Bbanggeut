import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// AR 탭이 쓰는 Banuba 엔진 다리.
///
/// **편집기는 우리 것이다.** 컷·글자·스티커·색감·저장은 전부 Flutter와 media3가
/// 맡는다. Banuba는 AR 탭이 얼굴 추적을 빌려 쓰는 엔진일 뿐이고, 그 화면으로
/// 넘어가는 길은 없다.
///
/// 채널 이름은 Kotlin의 `BanubaMaskContract`와 **글자까지 같아야** 한다. 다르면
/// Flutter는 `MissingPluginException`만 던지고 네이티브에는 아무 로그도 안 남는다.
class BanubaMaskChannel {
  const BanubaMaskChannel();

  static const channelName = 'com.williamjames/banuba_mask';
  static const eventChannelName = 'com.williamjames/banuba_mask_events';
  static const viewType = 'com.williamjames/banuba_mask_preview';

  static const _channel = MethodChannel(channelName);
  static const _events = EventChannel(eventChannelName);

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 재생 위치·상태·마스크 변경이 올라온다.
  Stream<BanubaMaskEvent> get events =>
      _events.receiveBroadcastStream().map(BanubaMaskEvent.fromNative);

  /// 엔진을 세우고 쓸 수 있는 마스크를 돌려준다. 여러 번 불러도 안전하다.
  /// 실패하면 빈 목록 — AR 탭이 열리지 않게 하는 대신 마스크만 비운다.
  Future<List<BanubaMask>> initialize(String licenseToken) async {
    if (!isSupported) return const [];
    try {
      final masks = await _channel.invokeListMethod<Object?>('initialize', {
        'token': licenseToken,
      });
      return (masks ?? const []).map(BanubaMask.fromNative).toList();
    } on PlatformException catch (failure) {
      debugPrint('[BanubaMask] initialize 실패: ${failure.code} ${failure.message}');
      return const [];
    } on MissingPluginException {
      debugPrint('[BanubaMask] 네이티브 채널이 등록되지 않았어요.');
      return const [];
    }
  }

  /// 미리보기에 영상을 물린다. 실패하면 사람이 읽을 수 있는 이유를 준다.
  Future<String?> setVideoSource({
    required String videoPath,
    required int width,
    required int height,
    required int durationMs,
    required int startMs,
    required int endMs,
    required double volume,
  }) => _guard('setVideoSource', {
    'videoPath': videoPath,
    'width': width,
    'height': height,
    'durationMs': durationMs,
    'startMs': startMs,
    'endMs': endMs,
    'volume': volume,
  });

  Future<String?> play() => _guard('play', const {});

  Future<String?> pause() => _guard('pause', const {});

  /// 탐색은 **마지막 목표만** 보낸다.
  ///
  /// 타임라인을 끌면 손가락이 초당 수십 번 움직이는데 네이티브 탐색은 그보다
  /// 느리다. 오는 대로 다 보내면 요청이 밀려 화면이 계속 버벅인다 — 앞의 것은
  /// 버리고 마지막만 보낸다.
  static int? _pendingSeekMs;
  static bool _seeking = false;

  Future<String?> seekTo(int positionMs) async {
    _pendingSeekMs = positionMs;
    if (_seeking) return null;
    _seeking = true;
    try {
      while (_pendingSeekMs != null) {
        final target = _pendingSeekMs!;
        _pendingSeekMs = null;
        final error = await _guard('seekTo', {'positionMs': target});
        if (error != null) return error;
      }
      return null;
    } finally {
      _seeking = false;
    }
  }

  /// 얼굴 마스크를 건다. null이면 마스크만 걷어낸다.
  Future<String?> applyMask(String? maskName) => maskName == null
      ? _guard('removeMask', const {})
      : _guard('applyMask', {'maskName': maskName});

  /// AR 탭을 벗어난다. 재생을 세워 Flutter 재생기와 소리가 겹치지 않게 한다.
  Future<String?> leave() => _guard('dispose', const {});

  /// 고른 마스크를 영상에 **구워** 중간 파일을 만든다.
  ///
  /// 저장을 누른 그 순간에만 부른다. 마스크를 고를 때마다 구우면 몇 번 눌러
  /// 보는 것만으로 몇 분이 날아간다.
  ///
  /// [ranges]는 컷 편집이 정한 조각들이고 **순서대로 이어 붙여** 한 편이 된다.
  /// 그래서 결과 파일은 이미 잘린 영상이고, 이어지는 media3 파이프라인은 그걸
  /// 통째로 원본 삼아 글자·스티커·색감·자막을 얹는다.
  ///
  /// 진행률은 [events]에 `exportProgress`로 올라온다.
  Future<BanubaMaskExport> export({
    required String licenseToken,
    required String videoPath,
    required List<({int startMs, int endMs})> ranges,
    required int durationMs,
    required int width,
    required int height,
    required String maskName,
    required String outputPath,
  }) async {
    if (!isSupported) {
      return const BanubaMaskExport.failed('Android에서만 동작해요.');
    }
    try {
      final path = await _channel.invokeMethod<String>('export', {
        'token': licenseToken,
        'videoPath': videoPath,
        'ranges': [
          for (final range in ranges)
            {'startMs': range.startMs, 'endMs': range.endMs},
        ],
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'maskName': maskName,
        'outputPath': outputPath,
      });
      if (path == null || path.isEmpty) {
        return const BanubaMaskExport.failed('마스크를 입힌 영상을 만들지 못했어요.');
      }
      return BanubaMaskExport.done(path);
    } on PlatformException catch (failure) {
      return BanubaMaskExport.failed(
        failure.message ?? failure.code,
        cancelled: failure.code == 'BANUBA_EXPORT_CANCELLED',
      );
    } on MissingPluginException {
      return const BanubaMaskExport.failed('AR 엔진을 찾지 못했어요.');
    }
  }

  /// 굽던 것을 그만둔다. [export]는 취소로 끝난다.
  Future<void> cancelExport() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('cancelExport', const {});
    } on PlatformException {
      // 이미 끝났을 수 있다. export 쪽 결과가 진실이다.
    } on MissingPluginException {
      // 채널이 없으면 굽고 있지도 않다.
    }
  }

  Future<String?> _guard(String method, Map<String, Object?> args) async {
    if (!isSupported) return 'Android에서만 동작해요.';
    try {
      await _channel.invokeMethod<void>(method, args);
      return null;
    } on PlatformException catch (failure) {
      return failure.message ?? failure.code;
    } on MissingPluginException {
      return 'AR 엔진을 찾지 못했어요.';
    }
  }
}

/// 마스크 굽기의 결말.
///
/// 취소를 실패와 가른다. 사용자가 그만둔 것은 오류가 아니라서 화면이 다르게
/// 말해야 한다 — "저장하지 못했어요"가 아니라 "그만뒀어요, 편집은 그대로예요".
@immutable
class BanubaMaskExport {
  const BanubaMaskExport.done(this.path) : message = null, cancelled = false;

  const BanubaMaskExport.failed(this.message, {this.cancelled = false})
    : path = null;

  /// 구워진 중간 파일. 실패했으면 null이고 파일도 남지 않는다.
  final String? path;
  final String? message;
  final bool cancelled;
}

/// 마스크 카드 하나.
///
/// **목록도 그림도 네이티브가 준다.** 효과 폴더는 언제든 갈아 끼울 수 있어야
/// 하는데, Flutter 에셋으로 선언해 두면 폴더가 바뀔 때마다 pubspec과 어긋나
/// 빌드가 깨진다. 여기서는 `config.js`가 있는 폴더만 이름으로 오고, 그림은
/// 앱 내부 저장소로 꺼내진 파일 경로로 온다(없으면 null).
@immutable
class BanubaMask {
  const BanubaMask({required this.name, this.previewPath});

  factory BanubaMask.fromNative(Object? raw) {
    final map = raw is Map ? raw : const {};
    return BanubaMask(
      name: map['name'] as String? ?? '',
      previewPath: map['previewPath'] as String?,
    );
  }

  /// 효과 폴더 이름. 그대로 엔진에 넘긴다.
  final String name;
  final String? previewPath;

  /// 카드에 쓸 이름. 폴더 이름의 밑줄을 띄어쓰기로만 바꾼다 — 사람이 붙인
  /// 이름을 우리가 멋대로 번역하지 않는다.
  String get label => name.replaceAll('_', ' ');
}

/// 네이티브에서 올라오는 소식.
@immutable
class BanubaMaskEvent {
  const BanubaMaskEvent({
    required this.type,
    this.positionMs,
    this.state,
    this.mask,
    this.message,
    this.progress,
  });

  factory BanubaMaskEvent.fromNative(Object? raw) {
    final map = raw is Map ? raw : const {};
    return BanubaMaskEvent(
      type: map['type'] as String? ?? 'unknown',
      positionMs: (map['positionMs'] as num?)?.toInt(),
      state: map['state'] as String?,
      mask: map['mask'] as String?,
      message: map['message'] as String?,
      progress: (map['progress'] as num?)?.toDouble(),
    );
  }

  /// `position` / `state` / `mask` / `error` / `exportProgress`.
  final String type;
  final int? positionMs;
  final String? state;
  final String? mask;
  final String? message;

  /// 마스크를 굽는 진행률(0~1). `exportProgress`일 때만 있다.
  final double? progress;
}

/// 편집 화면 **안**에 박히는 네이티브 미리보기.
///
/// AR 탭에 있는 동안에만 이 뷰가 재생을 맡는다. 다른 탭에서는 기존 Flutter
/// 재생기가 그대로 쓰이고, 둘이 동시에 소리를 내지 않도록 전환은 편집 화면이
/// 한 줄기로 관리한다.
class BanubaMaskPreviewView extends StatelessWidget {
  const BanubaMaskPreviewView({super.key});

  @override
  Widget build(BuildContext context) => const AndroidView(
    viewType: BanubaMaskChannel.viewType,
    creationParamsCodec: StandardMessageCodec(),
  );
}
