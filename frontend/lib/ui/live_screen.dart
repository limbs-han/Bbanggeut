import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/whep_player_controller.dart';
import '../core/whip_publisher_controller.dart';
import 'widgets.dart';

class EmbeddedLivePlayer extends StatefulWidget {
  const EmbeddedLivePlayer({
    super.key,
    required this.controller,
    required this.device,
    this.isActive = true,
    required this.status,
    this.houseMode = false,
  });

  final AppController controller;
  final DeviceSummary device;
  final bool isActive;
  final DeviceStatus? status;
  final bool houseMode;

  @override
  State<EmbeddedLivePlayer> createState() => _EmbeddedLivePlayerState();
}

class LiveViewingScreen extends StatelessWidget {
  const LiveViewingScreen({
    super.key,
    required this.controller,
    required this.device,
    required this.status,
  });

  final AppController controller;
  final DeviceSummary device;
  final DeviceStatus? status;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(device.name)),
    body: AppBackdrop(
      child: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
          children: [
            EmbeddedLivePlayer(
              controller: controller,
              device: device,
              status: status,
            ),
          ],
        ),
      ),
    ),
  );
}

class _EmbeddedLivePlayerState extends State<EmbeddedLivePlayer>
    with WidgetsBindingObserver {
  StreamSession? session;
  late final WhepPlayerController whepPlayer;
  late final WhipPublisherController talkbackPublisher;
  Timer? pollTimer;
  Timer? heartbeatTimer;
  Timer? controlsTimer;
  String? error;
  bool closing = false;
  bool muted = false;
  bool paused = false;
  bool started = false;
  bool starting = false;
  bool controlsVisible = false;
  bool webRtcWasConnected = false;
  bool talking = false;
  bool talkbackBusy = false;
  Future<void>? preferredPlayerFuture;

  bool get hasPlayback => whepPlayer.connected;

  @override
  void initState() {
    super.initState();
    whepPlayer = WhepPlayerController()..addListener(_handleWebRtcState);
    talkbackPublisher = WhipPublisherController();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 발화 중에는 내 재생을 강제로 뮤트한다. 기기에는 에코 제거가 없어서
  /// 기기 스피커 → 기기 마이크 → 앱 → 기기로 도는 순환을 앱이 끊어야 한다.
  Future<void> _applyPlaybackMute() => whepPlayer.setMuted(muted || talking);

  void _handleWebRtcState() {
    if (!mounted) return;
    if (whepPlayer.connected) {
      webRtcWasConnected = true;
      setState(() => error = null);
      return;
    }
    if (!webRtcWasConnected || closing) {
      setState(() {});
      return;
    }
    webRtcWasConnected = false;
    setState(() {
      error = 'WebRTC 연결이 끊어졌습니다. 다시 시도해 주세요.';
    });
  }

  @override
  void didUpdateWidget(covariant EmbeddedLivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id) {
      started = false;
      controlsVisible = false;
      unawaited(_closeForDeviceChange());
      return;
    }
    if (oldWidget.isActive && !widget.isActive) {
      unawaited(_suspend());
    } else if (!oldWidget.isActive &&
        widget.isActive &&
        started &&
        !paused &&
        !hasPlayback) {
      unawaited(_restart());
    }
  }

  Future<void> _suspend() async {
    await _close(disposePlayer: true);
    if (!mounted) return;
    setState(() {
      controlsVisible = false;
      starting = false;
    });
  }

  Future<void> _start() async {
    if (starting || !widget.isActive) return;
    setState(() {
      started = true;
      paused = false;
      starting = true;
      closing = false;
      error = null;
    });
    if (widget.status?.isOnline == false) {
      if (mounted) {
        setState(() {
          error = '카메라가 오프라인이에요.';
          starting = false;
        });
      }
      return;
    }
    try {
      session = await widget.controller.api.createStream(widget.device.id);
      if (!mounted || closing) return;
      heartbeatTimer = Timer.periodic(
        Duration(seconds: session!.heartbeatIntervalSeconds),
        (_) => _heartbeat(),
      );
      await _checkStatus();
      if (session?.isReady != true && !closing) {
        pollTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => _checkStatus(),
        );
      }
    } catch (failure) {
      if (mounted && !closing) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> _openPreferredPlayer(StreamSession updated) {
    final existing = preferredPlayerFuture;
    if (existing != null) return existing;
    final operation = _openPreferredPlayerInternal(updated);
    preferredPlayerFuture = operation;
    return operation.whenComplete(() {
      if (identical(preferredPlayerFuture, operation)) {
        preferredPlayerFuture = null;
      }
    });
  }

  Future<void> _openPreferredPlayerInternal(StreamSession updated) async {
    final whepUrl = updated.whepUrl;
    if (whepUrl == null || whepUrl.isEmpty) {
      throw const WhepPlaybackException();
    }
    await _applyPlaybackMute();
    await whepPlayer.connect(whepUrl);
    if (mounted && !closing) setState(() => error = null);
  }

  Future<void> _startTalking() async {
    final current = session;
    if (current == null || !hasPlayback || talking || talkbackBusy) return;
    setState(() => talkbackBusy = true);
    try {
      final talkback = await widget.controller.api.openTalkback(current.id);
      talking = true;
      await _applyPlaybackMute();
      await talkbackPublisher.connect(talkback.whipUrl);
      if (!mounted) return;
      setState(() {});
    } catch (failure) {
      talking = false;
      await talkbackPublisher.close();
      await _applyPlaybackMute();
      try {
        await widget.controller.api.closeTalkback(current.id);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(_talkbackMessage(failure))),
        );
      }
    } finally {
      if (mounted) setState(() => talkbackBusy = false);
    }
  }

  Future<void> _stopTalking() async {
    if (!talking && !talkbackPublisher.transmitting) return;
    final current = session;
    talking = false;
    if (mounted) setState(() {});
    await talkbackPublisher.close();
    await _applyPlaybackMute();
    if (current != null) {
      try {
        await widget.controller.api.closeTalkback(current.id);
      } catch (_) {}
    }
  }

  String _talkbackMessage(Object failure) {
    final text = '$failure';
    if (text.contains('TALKBACK_BUSY')) return '다른 구성원이 말하는 중이에요.';
    if (text.contains('SPEAKER_UNAVAILABLE')) return '이 카메라에는 스피커가 없어요.';
    return text;
  }

  Future<void> _heartbeat() async {
    final current = session;
    if (current == null || closing) return;
    try {
      await widget.controller.api.heartbeatStream(current.id);
    } catch (_) {}
  }

  Future<void> _checkStatus() async {
    final current = session;
    if (current == null || closing) return;
    try {
      final updated = await widget.controller.api.getStream(current.id);
      if (!mounted || closing) return;
      session = updated;
      if (updated.isReady) {
        pollTimer?.cancel();
        await _openPreferredPlayer(updated);
      } else if (const {
        'FAILED',
        'CLOSED',
        'EXPIRED',
      }.contains(updated.status)) {
        _cancelTimers();
        if (mounted) {
          setState(() => error = updated.failureCode ?? '라이브 세션이 종료됐어요.');
        }
      }
    } catch (failure) {
      if (mounted && !closing) {
        setState(() => error = '$failure');
      }
    }
  }

  void _cancelTimers() {
    pollTimer?.cancel();
    heartbeatTimer?.cancel();
    pollTimer = null;
    heartbeatTimer = null;
    controlsTimer?.cancel();
    controlsTimer = null;
  }

  Future<void> _close({bool disposePlayer = false}) async {
    if (closing) return;
    closing = true;
    _cancelTimers();
    // 발화 권한을 먼저 놓는다. 라이브 세션이 사라진 뒤에는 반납할 대상이 없어
    // 기기가 만료까지 스피커를 열어 둔다.
    await _stopTalking();
    final current = session;
    session = null;
    if (disposePlayer) {
      await whepPlayer.close();
      webRtcWasConnected = false;
    }
    if (current != null) {
      try {
        await widget.controller.api.closeStream(current.id);
      } catch (_) {}
    }
  }

  Future<void> _restart() async {
    await _close(disposePlayer: true);
    if (!mounted) return;
    setState(() {
      closing = false;
      paused = false;
      error = null;
    });
    await _start();
  }

  Future<void> _pause() async {
    if (!hasPlayback || closing) return;
    await _close(disposePlayer: true);
    if (!mounted) return;
    setState(() {
      paused = true;
      closing = false;
      controlsVisible = true;
    });
  }

  Future<void> _goLive() async {
    if (starting || !widget.isActive) return;
    if (hasPlayback && !paused) return;
    await _restart();
  }

  Future<void> _closeForDeviceChange() async {
    await _close(disposePlayer: true);
    if (!mounted) return;
    setState(() {
      closing = false;
      error = null;
      starting = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_close(disposePlayer: true));
    } else if (state == AppLifecycleState.resumed &&
        closing &&
        started &&
        !paused) {
      unawaited(_restart());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controlsTimer?.cancel();
    unawaited(_close());
    whepPlayer.removeListener(_handleWebRtcState);
    whepPlayer.dispose();
    talkbackPublisher.dispose();
    super.dispose();
  }

  Future<void> _openFullscreen() async {
    if (!whepPlayer.connected) return;
    try {
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => FullscreenWhepView(
            player: whepPlayer,
            title: widget.device.name,
            initialMuted: muted,
            onReturnToLive: _restart,
            onMutedChanged: (value) {
              if (mounted) setState(() => muted = value);
            },
          ),
        ),
      );
    } finally {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  void _handleVideoTap() {
    if (!hasPlayback) {
      if (!starting) {
        if (started) {
          unawaited(_restart());
        } else {
          unawaited(_start());
        }
      }
      return;
    }
    setState(() => controlsVisible = !controlsVisible);
    if (controlsVisible) _scheduleControlsHide();
  }

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    radius: widget.houseMode ? 0 : 24,
    borderColor: Colors.transparent,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(widget.houseMode ? 0 : 24),
      child: Column(
        children: [
          AspectRatio(
            // 바깥 홈 카드의 3px 테두리가 차지하는 실제 높이를 제외한다.
            // 4:3을 그대로 쓰면 S24+ 폭에서 내부가 1.5px 넘친다.
            aspectRatio: widget.houseMode ? 1.34 : 16 / 9,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleVideoTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _videoBody(),
                  if (!hasPlayback)
                    Center(
                      child: IconButton.filled(
                        key: const Key('live-play-button'),
                        onPressed: starting ? null : _handleVideoTap,
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xB33A2C22),
                          foregroundColor: Colors.white,
                          fixedSize: const Size.square(58),
                        ),
                        icon: starting
                            ? const SizedBox.square(
                                dimension: 23,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                error == null
                                    ? Icons.play_arrow_rounded
                                    : Icons.refresh_rounded,
                                size: 34,
                              ),
                      ),
                    ),
                  Positioned(
                    left: 12,
                    top: widget.houseMode ? 30 : 12,
                    child: InkWell(
                      key: const Key('live-edge-button'),
                      borderRadius: BorderRadius.circular(99),
                      onTap: paused ? _goLive : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: hasPlayback
                              ? const Color(0xDDD32F2F)
                              : const Color(0xB32D312B),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          paused
                              ? 'LIVE로 돌아가기'
                              : started
                              ? '●  LIVE'
                              : 'LIVE 준비',
                          style: TextStyle(
                            color: hasPlayback ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (hasPlayback && widget.houseMode)
                    Positioned(
                      right: 14,
                      top: 14,
                      child: IconButton.filled(
                        tooltip: '전체 화면',
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xEFFFFFFF),
                          foregroundColor: AppColors.ink,
                          fixedSize: const Size.square(48),
                        ),
                        onPressed: _openFullscreen,
                        icon: const Icon(Icons.open_in_full_rounded),
                      ),
                    ),
                  if (hasPlayback && widget.houseMode)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 18,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xA6654A34),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: muted ? '소리 켜기' : '음소거',
                                color: Colors.white,
                                onPressed: () {
                                  setState(() => muted = !muted);
                                  unawaited(_applyPlaybackMute());
                                },
                                icon: Icon(
                                  muted
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                ),
                              ),
                              const SizedBox(width: 12),
                              _PushToTalkButton(
                                talking: talking,
                                busy: talkbackBusy,
                                onStart: _startTalking,
                                onStop: _stopTalking,
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                key: const Key('live-pause-button'),
                                tooltip: '일시정지',
                                color: Colors.white,
                                onPressed: _pause,
                                icon: const Icon(Icons.pause_rounded),
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                tooltip: '전체 화면',
                                color: Colors.white,
                                onPressed: _openFullscreen,
                                icon: const Icon(Icons.fullscreen_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (hasPlayback && !widget.houseMode) ...[
                    Positioned(
                      right: 106,
                      bottom: 10,
                      child: AnimatedOpacity(
                        opacity: controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: IgnorePointer(
                          ignoring: !controlsVisible,
                          child: IconButton.filled(
                            key: const Key('live-pause-button'),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0x99000000),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _pause,
                            icon: const Icon(Icons.pause_rounded),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 58,
                      bottom: 10,
                      child: AnimatedOpacity(
                        opacity: controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: IgnorePointer(
                          ignoring: !controlsVisible,
                          child: IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0x99000000),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              setState(() => muted = !muted);
                              unawaited(whepPlayer.setMuted(muted));
                              _scheduleControlsHide();
                            },
                            icon: Icon(
                              muted
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: AnimatedOpacity(
                        opacity: controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: IgnorePointer(
                          ignoring: !controlsVisible,
                          child: IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0x99000000),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _openFullscreen,
                            icon: const Icon(Icons.fullscreen_rounded),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!widget.houseMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.device.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.status?.personCount == null
                              ? '${widget.status?.isOnline == true ? '온라인' : '연결 준비 중'} · 실시간 영상'
                              : '온라인 · 가족 ${widget.status!.personCount}명 감지',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const StatusPill(label: 'LIVE', color: AppColors.greenCard),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _videoBody() {
    if (whepPlayer.connected) {
      return ColoredBox(
        color: Colors.black,
        child: RTCVideoView(
          whepPlayer.renderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        ),
      );
    }
    if (!started) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF38413B), Color(0xFF171A18)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Icon(
            Icons.camera_indoor_rounded,
            size: 72,
            color: Color(0x66FFFFFF),
          ),
        ),
      );
    }
    return ColoredBox(
      color: const Color(0xFF171A18),
      child: Center(
        child: error == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
      ),
    );
  }
}

/// 누르는 동안만 말하는 무전기식 버튼.
///
/// 토글이 아니라 푸시투토크인 이유는 기기당 발화자가 한 명이기 때문이다.
/// 켜 둔 것을 잊으면 다른 구성원이 그동안 말할 수 없다.
class _PushToTalkButton extends StatelessWidget {
  const _PushToTalkButton({
    required this.talking,
    required this.busy,
    required this.onStart,
    required this.onStop,
  });

  final bool talking;
  final bool busy;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('live-push-to-talk-button'),
      onTapDown: (_) => unawaited(onStart()),
      onTapUp: (_) => unawaited(onStop()),
      onTapCancel: () => unawaited(onStop()),
      child: Tooltip(
        message: talking ? '말하는 중' : '길게 눌러 말하기',
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: talking ? const Color(0xFFE0533D) : Colors.transparent,
          ),
          child: busy && !talking
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  talking ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }
}

class FullscreenWhepView extends StatefulWidget {
  const FullscreenWhepView({
    super.key,
    required this.player,
    required this.title,
    required this.initialMuted,
    required this.onReturnToLive,
    required this.onMutedChanged,
  });

  final WhepPlayerController player;
  final String title;
  final bool initialMuted;
  final Future<void> Function() onReturnToLive;
  final ValueChanged<bool> onMutedChanged;

  @override
  State<FullscreenWhepView> createState() => _FullscreenWhepViewState();
}

class _FullscreenWhepViewState extends State<FullscreenWhepView> {
  bool controlsVisible = true;
  late bool muted;
  Timer? controlsTimer;

  @override
  void initState() {
    super.initState();
    muted = widget.initialMuted;
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  @override
  void dispose() {
    controlsTimer?.cancel();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => controlsVisible = !controlsVisible);
        if (controlsVisible) _scheduleControlsHide();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          RTCVideoView(
            widget.player.renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0x99000000),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_fullscreen_rounded),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${widget.title} · WebRTC LIVE',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton.filled(
                          key: const Key('fullscreen-mute-button'),
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0x99000000),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            setState(() => muted = !muted);
                            widget.onMutedChanged(muted);
                            unawaited(widget.player.setMuted(muted));
                            _scheduleControlsHide();
                          },
                          icon: Icon(
                            muted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        TextButton.icon(
                          key: const Key('fullscreen-live-edge-button'),
                          onPressed: () async {
                            await widget.onReturnToLive();
                            if (mounted) _scheduleControlsHide();
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xCCFFF9F5),
                            foregroundColor: const Color(0xFFE53935),
                          ),
                          icon: const Icon(Icons.circle, size: 9),
                          label: const Text(
                            'LIVE',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'WebRTC 실시간 · DVR 미지원',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
