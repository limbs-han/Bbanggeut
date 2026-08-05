import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// 뽑기 연출이 필요한 소리. 컨트롤러는 이 계약만 보고, 실제 오디오 재생은
/// [LaughDrawSound]가 맡는다 — 테스트에서 플랫폼 채널을 타지 않게 하기 위한
/// 최소한의 경계다.
abstract class LaughDrawSoundEffects {
  Future<void> playDrawStart();
  Future<void> playDrawComplete();
  Future<void> stop();
  Future<void> dispose();
}

/// 뽑기 연출에 붙는 효과음.
///
/// 음원은 저작권이 불분명한 외부 파일을 받아 온 것이 아니라
/// `tool/generate_laugh_draw_sfx.dart`가 직접 합성해 구운 WAV다. 소리를 고치고
/// 싶으면 그 스크립트를 손보고 다시 실행하면 된다.
///
/// **왜 플레이어를 두 개 두는가**: 시작음(1.85초)이 끝나기 전에 당첨음이 겹쳐
/// 울려야 "떨어졌다"는 느낌이 산다. 플레이어 하나로 두 소리를 번갈아 틀면
/// 뒤 소리가 앞 소리를 끊어 버린다. 대신 같은 소리끼리는 겹치지 않는다 —
/// 연속 탭으로 시작음이 여러 겹 쌓이는 일이 없다.
class LaughDrawSound implements LaughDrawSoundEffects {
  LaughDrawSound({AudioPlayer? startPlayer, AudioPlayer? completePlayer})
    : _start = startPlayer,
      _complete = completePlayer;

  static const startAsset = 'audio/laugh_draw_start.wav';
  static const completeAsset = 'audio/laugh_draw_complete.wav';

  /// 음량. 시스템 음량은 건드리지 않고 이 트랙의 크기만 정한다.
  ///
  /// 처음에는 둘 다 0.5였는데 S24 Plus 스피커에서 거의 들리지 않았다. 당첨음은
  /// 시작음이 아직 울리는 중에 겹쳐 나므로 조금 더 크게 둔다.
  static const _startVolume = 0.7;
  static const _completeVolume = 0.75;

  /// 플레이어는 **처음 소리를 낼 때** 만든다. 화면을 열자마자 네이티브 플레이어를
  /// 두 개 붙잡아 두면 영상 재생기와 오디오 포커스를 두고 부딪힐 수 있다.
  AudioPlayer? _start;
  AudioPlayer? _complete;

  bool _stopped = false;
  bool _disposed = false;

  /// 마지막 재생 실패 사유. 화면이 상태 보고에 쓸 수 있게 남겨 둔다(무음 모드,
  /// 오디오 포커스 거절 등). 실패해도 뽑기 자체는 그대로 진행된다.
  String? lastError;

  /// 뽑기 버튼을 누른 순간. 공이 굴러가는 소리를 한 번만 재생한다.
  @override
  Future<void> playDrawStart() async {
    _stopped = false;
    _start = await _play(_start, 'laugh-draw-start', startAsset, _startVolume);
    await _vibrate(HapticFeedback.mediumImpact);
  }

  /// 당첨 공이 떨어지는 순간. 오류일 때는 화면이 부르지 않는다.
  @override
  Future<void> playDrawComplete() async {
    _complete = await _play(
      _complete,
      'laugh-draw-complete',
      completeAsset,
      _completeVolume,
    );
    await _vibrate(HapticFeedback.selectionClick);
  }

  /// 화면을 벗어나거나 앱이 백그라운드로 갈 때. 지금 울리는 소리를 끊고,
  /// 이 뒤에 오는 재생 요청도 막는다 — 영상 재생과 소리가 겹치지 않게.
  @override
  Future<void> stop() async {
    _stopped = true;
    await _quiet(_start);
    await _quiet(_complete);
  }

  @override
  Future<void> dispose() async {
    _stopped = true;
    _disposed = true;
    await _release(_start);
    await _release(_complete);
    _start = null;
    _complete = null;
  }

  /// 필요하면 플레이어를 만들어 소리를 낸다. 만들어 둔 플레이어를 돌려준다.
  Future<AudioPlayer?> _play(
    AudioPlayer? existing,
    String playerId,
    String asset,
    double volume,
  ) async {
    if (_disposed || _stopped) return existing;
    var player = existing;
    try {
      if (player == null) {
        player = AudioPlayer(playerId: playerId);
        // 짧은 효과음이라 끝나면 멈춘 상태로 두고 소스는 캐시에 남긴다.
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setPlayerMode(PlayerMode.lowLatency);
      }
      // 같은 소리를 다시 틀 때는 처음으로 되감는다. stop 없이 play만 부르면
      // 이미 끝까지 간 플레이어가 그대로 멈춰 있어 두 번째 탭에서 소리가 안 난다.
      await player.stop();
      if (_disposed || _stopped) return player;
      await player.play(AssetSource(asset), volume: volume);
    } catch (error) {
      // 무음 모드나 오디오 포커스 실패가 뽑기를 막으면 안 된다.
      lastError = '$error';
    }
    return player;
  }

  Future<void> _vibrate(Future<void> Function() haptic) async {
    if (_disposed) return;
    try {
      await haptic();
    } catch (_) {
      // 진동이 없는 기기도 있다.
    }
  }

  Future<void> _quiet(AudioPlayer? player) async {
    if (player == null) return;
    try {
      await player.stop();
    } catch (_) {
      // 아직 아무것도 재생하지 않았으면 멈출 것도 없다.
    }
  }

  Future<void> _release(AudioPlayer? player) async {
    if (player == null) return;
    try {
      await player.dispose();
    } catch (_) {
      // 이미 정리된 플레이어.
    }
  }
}
