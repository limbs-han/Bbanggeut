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

  /// 비활성으로 바뀐 순간 라이브를 놓아야 하는가.
  ///
  /// 홈은 다른 화면이 위를 덮으면 [isActive]를 내려 라이브를 끈다 — 보이지도
  /// 않는 스트림이 배터리와 데이터를 먹으니 옳다. 문제는 전체 화면도 라우트를
  /// push한다는 점이었다. 전체 화면은 이 위젯의 플레이어를 그대로 받아 그리는데,
  /// 홈이 그 플레이어를 닫고 버려서 전체 화면을 누르면 라이브가 그 자리에서
  /// 끊겼다. 전체 화면은 라이브가 계속 돌아야 하는 유일한 라우트다.
  @visibleForTesting
  static bool shouldSuspend({
    required bool wasActive,
    required bool isActive,
    required bool fullscreenOpen,
  }) => wasActive && !isActive && !fullscreenOpen;

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

/// 왼쪽 위 LIVE 표시등.
///
/// 빨간 불이 켜져 있으면 지금 보는 그림이 **실시간 맨 앞**이라는 뜻이고,
/// 꺼져 있으면 화면이 멈췄거나 지연이 쌓여 뒤처졌다는 뜻이다. 뒤처졌을 때
/// 누르면 맨 앞으로 다시 당긴다 — WebRTC 라이브에는 되감기 버퍼가 없어서
/// "맨 앞으로 간다"는 곧 재생 연결을 다시 맺는 일이다.
///
/// 작은 화면과 전체 화면이 **같은 위젯**을 쓴다. 두 곳에서 불빛의 뜻이
/// 달라지면 그 표시는 믿을 수 없는 표시가 된다.
class LiveEdgeChip extends StatelessWidget {
  const LiveEdgeChip({
    super.key,
    required this.atLiveEdge,
    required this.label,
    required this.onTap,
  });

  /// 빨간 불을 켤지.
  final bool atLiveEdge;
  final String label;

  /// null이면 지금은 누를 수 없다(이미 맨 앞이거나 연결하는 중).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: atLiveEdge ? const Color(0xDDD32F2F) : const Color(0xB32D312B),
    borderRadius: BorderRadius.circular(99),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              key: const Key('live-edge-lamp'),
              duration: const Duration(milliseconds: 220),
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 켜졌을 때는 빨간 바탕 위의 흰 불, 꺼졌을 때는 어두운
                // 바탕 위의 식은 빨강 — 한눈에 켜짐/꺼짐이 갈린다.
                color: atLiveEdge
                    ? Colors.white
                    : const Color(0xFF7A4B45),
                boxShadow: atLiveEdge
                    ? const [
                        BoxShadow(color: Color(0x88FFFFFF), blurRadius: 6),
                      ]
                    : const [],
              ),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: atLiveEdge ? Colors.white : Colors.white70,
                fontWeight: FontWeight.w900,
              ),
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
  DateTime? warmupDeadline;
  bool talking = false;
  bool talkbackBusy = false;
  Future<void>? preferredPlayerFuture;

  /// 실시간 맨 앞으로 다시 붙는 중. 이때 끊기는 것은 고장이 아니라 우리가
  /// 일부러 끊은 것이라 "연결이 끊어졌습니다"를 띄우면 안 된다.
  bool resyncing = false;

  /// 전체 화면이 이 플레이어를 들고 위에 떠 있다.
  ///
  /// **왜 필요한가**: 홈은 다른 화면이 위를 덮으면 [EmbeddedLivePlayer.isActive]를
  /// 내려 라이브를 끈다(배터리·데이터). 전체 화면도 라우트를 push하므로 그
  /// 규칙에 걸려, 전체 화면이 방금 넘겨받은 플레이어를 홈이 닫고 버렸다 —
  /// 전체 화면을 누르면 라이브가 그 자리에서 끊겼다. 전체 화면은 라이브를
  /// 계속 봐야 하는 유일한 라우트라 이 구간만 규칙에서 뺀다.
  bool fullscreenOpen = false;

  bool get hasPlayback => whepPlayer.connected;

  /// 지금 보는 그림이 실시간 맨 앞인가. LIVE 표시등이 이것을 그린다.
  bool get atLiveEdge => hasPlayback && !paused && whepPlayer.atLiveEdge;

  String get liveChipLabel {
    if (paused) return 'LIVE로 돌아가기';
    if (!started) return 'LIVE 준비';
    // 한 번 붙었다가 끊긴 상태와 처음 여는 상태를 갈라 말한다 — 재연결 중이면
    // 사용자가 아무것도 하지 않아도 된다는 것을 알아야 한다.
    if (!hasPlayback) {
      if (reconnecting) return 'LIVE 재연결 중';
      return connecting ? 'LIVE 연결 중' : 'LIVE 다시 연결';
    }
    return atLiveEdge ? 'LIVE' : '실시간으로';
  }

  /// 보다가 끊겨 스스로 다시 붙고 있는 중인가.
  bool get reconnecting =>
      !hasPlayback && error == null && !closing && warmupDeadline != null &&
      session != null;

  /// 세션을 만든 순간부터 첫 프레임까지가 전부 "준비 중"이다. 이 동안 재생
  /// 버튼이 살아 있으면 조급한 탭이 _restart()로 이어져 진행 중이던 워밍업을
  /// 매번 처음으로 되돌린다.
  bool get connecting =>
      !hasPlayback && error == null && !closing && (starting || session != null);

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

  /// 끊긴 뒤 스스로 다시 붙어 보는 시간.
  ///
  /// 서버가 미디어 끊김을 30초에 판정하고 120초까지 세션을 재연결 대기로
  /// 살려 둔다(StreamMediaReconcileWorker). 앱이 더 짧게 포기하면 살아 있는
  /// 세션을 앞에 두고 "다시 시도해 주세요"를 띄우게 되므로 같은 눈금을 쓴다.
  static const _reconnectWindow = Duration(seconds: 120);

  void _handleWebRtcState() {
    if (!mounted) return;
    if (whepPlayer.connected) {
      webRtcWasConnected = true;
      warmupDeadline = null;
      setState(() => error = null);
      return;
    }
    if (!webRtcWasConnected || closing || resyncing) {
      setState(() {});
      return;
    }
    webRtcWasConnected = false;
    // **막다른 길로 끝내지 않는다.** 실제로 잡히는 끊김의 대부분은 송출이 몇 초
    // 밀린 것이고, 서버는 그동안 세션을 재연결 대기로 살려 둔다. 예전에는 여기서
    // 곧바로 오류를 띄웠고, 사용자는 카메라를 깨우는 몇 초를 처음부터 다시
    // 기다리며 라이브를 손으로 재시작해야 했다.
    warmupDeadline ??= DateTime.now().add(_reconnectWindow);
    setState(() => error = null);
    // 재생이 붙은 뒤에는 폴링을 멈춰 두었으므로 다시 켠다 — 세션이 READY로
    // 돌아오는 순간을 이것이 잡아 재생을 다시 연다.
    pollTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkStatus(),
    );
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
    if (EmbeddedLivePlayer.shouldSuspend(
      wasActive: oldWidget.isActive,
      isActive: widget.isActive,
      fullscreenOpen: fullscreenOpen,
    )) {
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
    warmupDeadline = null;
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
        try {
          await _openPreferredPlayer(updated);
          if (!mounted || closing) return;
          pollTimer?.cancel();
          pollTimer = null;
          warmupDeadline = null;
        } on WhepPlaybackException {
          if (!mounted || closing) return;
          // 기기의 READY는 "송출 프로세스가 살아 있다"는 신호일 뿐이라
          // MediaMTX에 스트림이 실제로 붙기 전일 수 있다. 첫 실패를 곧장
          // 에러로 보여주면 사용자가 다시 눌러 세션을 재시작하는 수밖에
          // 없으므로, 준비 표시를 유지한 채 조용히 다시 붙는다.
          //
          // 한 번 보다가 끊긴 경우에는 [_handleWebRtcState]가 이 기한을 미리
          // 재연결 창(120초)으로 늘려 둔다 — 처음 여는 25초와 달리, 서버가
          // 세션을 살려 두는 동안은 앱도 계속 붙어 봐야 한다.
          warmupDeadline ??= DateTime.now().add(const Duration(seconds: 25));
          if (DateTime.now().isAfter(warmupDeadline!)) {
            _cancelTimers();
            setState(() => error = '카메라 연결에 실패했어요. 다시 시도해 주세요.');
          } else {
            // 첫 조회부터 READY였다면 폴링이 아직 없다.
            pollTimer ??= Timer.periodic(
              const Duration(seconds: 2),
              (_) => _checkStatus(),
            );
            setState(() {});
          }
        }
      } else if (const {
        'FAILED',
        'CLOSED',
        'EXPIRED',
      }.contains(updated.status)) {
        _cancelTimers();
        if (mounted) {
          setState(() => error = _sessionEndedMessage(updated.failureCode));
        }
      }
    } catch (failure) {
      if (mounted && !closing) {
        setState(() => error = '$failure');
      }
    }
  }

  /// 세션이 끝난 이유를 사람이 읽는 문구로.
  ///
  /// 예전에는 서버 코드를 그대로 화면에 찍었다. 화면에 `MEDIA_NOT_FLOWING`이
  /// 떠 있으면 사용자는 무엇을 해야 하는지 알 수 없다.
  static String _sessionEndedMessage(String? failureCode) => switch (failureCode) {
    'MEDIA_NOT_FLOWING' => '카메라 연결이 오래 끊겨 있어 라이브를 멈췄어요.\n다시 시도해 주세요.',
    'NO_ACTIVE_VIEWERS' => '보는 사람이 없어 라이브를 멈췄어요.',
    null => '라이브 세션이 종료됐어요.',
    _ => '라이브가 끊겼어요. 다시 시도해 주세요.',
  };

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

  /// 실시간 맨 앞으로 당긴다. LIVE 표시등을 누르면 이것이 돈다.
  ///
  /// **왜 "새로고침"이 곧 실시간인가**: WebRTC 라이브에는 되감기 버퍼가 없다.
  /// 뒤처졌다는 것은 받고 있는 그림이 늦거나 멈춰 있다는 뜻이라, 맨 앞으로
  /// 가는 유일한 길은 재생 연결을 다시 맺는 것이다.
  ///
  /// 라이브 세션이 아직 살아 있으면 **그 세션에 다시 붙기만** 한다. 세션까지
  /// 새로 만들면 카메라를 깨우는 몇 초를 처음부터 다시 기다려야 한다.
  Future<void> _goLive() async {
    if (starting || closing || resyncing || !widget.isActive) return;
    if (!started) {
      await _start();
      return;
    }
    final current = session;
    if (paused || current == null || !current.isReady) {
      await _restart();
      return;
    }
    if (atLiveEdge) return;

    setState(() {
      resyncing = true;
      error = null;
    });
    var reconnected = false;
    try {
      await _openPreferredPlayer(current);
      reconnected = whepPlayer.connected;
    } catch (_) {
      reconnected = false;
    }
    if (!mounted) return;
    setState(() => resyncing = false);
    // 세션이 그새 만료됐을 수 있다. 그때는 처음부터 다시 연다.
    if (!reconnected) await _restart();
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
    // push보다 먼저 세워 둔다. push가 홈에 "덮였다"를 알리고, 그 알림이
    // didUpdateWidget으로 돌아오는 것이 이 함수가 await에서 깨어나기 전이다.
    fullscreenOpen = true;
    try {
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => FullscreenWhepView(
            player: whepPlayer,
            title: widget.device.name,
            initialMuted: muted,
            onGoLive: _goLive,
            onMutedChanged: (value) {
              if (mounted) setState(() => muted = value);
            },
          ),
        ),
      );
    } finally {
      fullscreenOpen = false;
      // 전체 화면에서 나왔는데 홈이 이미 다른 이유로 비활성이면(탭을 옮겼거나
      // 다른 화면이 덮고 있으면) 그때는 규칙대로 라이브를 놓는다.
      if (mounted && !widget.isActive) unawaited(_suspend());
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
      // 준비 중 탭을 무시하지 않으면 _restart()가 진행 중인 세션을 닫고
      // 워밍업을 처음부터 다시 시작한다.
      if (!connecting) {
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
          _LiveSurfaceBox(
            houseMode: widget.houseMode,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleVideoTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _videoBody(),
                  if (!hasPlayback)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton.filled(
                            key: const Key('live-play-button'),
                            onPressed: connecting ? null : _handleVideoTap,
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xB33A2C22),
                              foregroundColor: Colors.white,
                              fixedSize: const Size.square(58),
                            ),
                            icon: connecting
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
                          if (connecting)
                            Container(
                              key: const Key('live-warmup-caption'),
                              margin: const EdgeInsets.only(top: 10),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xB33A2C22),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                resyncing
                                    ? '실시간으로 따라가는 중이에요…'
                                    : '카메라를 깨우는 중이에요…',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: 12,
                    top: widget.houseMode ? 30 : 12,
                    child: LiveEdgeChip(
                      key: const Key('live-edge-button'),
                      atLiveEdge: atLiveEdge,
                      label: liveChipLabel,
                      // 이미 맨 앞이면 누를 것이 없다. 연결하는 중에 누르면
                      // 진행 중인 워밍업을 처음으로 되돌린다.
                      onTap: (atLiveEdge || connecting || resyncing)
                          ? null
                          : _goLive,
                    ),
                  ),
                  // 발화 중 라이브 소리가 꺼지는 것은 에코 차단을 위한 의도된
                  // 동작이다. 표시하지 않으면 사용자는 무음 버그로 오해한다.
                  if (hasPlayback && widget.houseMode && talking)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 14,
                      child: Center(
                        child: Container(
                          key: const Key('live-talking-indicator'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xCC33241B),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mic_rounded,
                                size: 16,
                                color: Color(0xFFE0533D),
                              ),
                              SizedBox(width: 6),
                              Text(
                                '말하는 중 · 라이브 소리 잠시 꺼짐',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ],
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
                                tooltip: talking
                                    ? '말하는 동안에는 소리가 꺼져요'
                                    : (muted ? '소리 켜기' : '음소거'),
                                color: Colors.white,
                                onPressed: () {
                                  setState(() => muted = !muted);
                                  unawaited(_applyPlaybackMute());
                                },
                                // 발화 중에는 실제로 재생이 꺼져 있으므로 아이콘도
                                // 꺼짐으로 보여야 한다. muted만 반영하면 소리가
                                // 안 나는데 🔊로 표시되는 거짓 상태가 된다.
                                icon: Icon(
                                  (muted || talking)
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
    required this.onGoLive,
    required this.onMutedChanged,
  });

  final WhepPlayerController player;
  final String title;
  final bool initialMuted;

  /// 실시간 맨 앞으로 당긴다. 작은 화면의 LIVE 표시등과 같은 동작이다.
  final Future<void> Function() onGoLive;
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
                        // 표시등은 작은 화면과 같은 자리(왼쪽 위), 같은 위젯,
                        // 같은 동작이다. 재생기가 실시간 상태를 알려 주므로
                        // 그것만 듣고 이 조각만 다시 그린다.
                        ListenableBuilder(
                          listenable: widget.player,
                          builder: (context, _) {
                            final atLiveEdge = widget.player.atLiveEdge;
                            return LiveEdgeChip(
                              key: const Key('fullscreen-live-edge-button'),
                              atLiveEdge: atLiveEdge,
                              label: atLiveEdge ? 'LIVE' : '실시간으로',
                              onTap: atLiveEdge
                                  ? null
                                  : () async {
                                      await widget.onGoLive();
                                      if (mounted) _scheduleControlsHide();
                                    },
                            );
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.title,
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
                    child: ListenableBuilder(
                      listenable: widget.player,
                      builder: (context, _) => Text(
                        widget.player.atLiveEdge
                            ? 'WebRTC 실시간 · 되감기 없음'
                            : '실시간에서 벗어났어요 · 위 LIVE를 눌러 따라잡기',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
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

/// 라이브 영상 표면의 높이를 정한다.
///
/// **홈 카드에서는 비율을 다시 걸지 않는다**: 바깥 홈 카드가 이미
/// `AspectRatio(4 / 3)`으로 높이를 정해 주기 때문에, 여기서 비율을 한 번 더
/// 걸면 두 제약이 어긋난다. 바깥 카드의 3px 테두리가 먹는 6px은 폭과 무관하게
/// 고정이라 비율로 보정하면 필요한 값이 폭마다 달라진다 — 그래서 예전에 쓰던
/// 1.34는 S24+ 기본 폭에서만 맞았고, 화면 크기 설정을 키워 논리 폭이 좁아지면
/// 소수점 단위로 다시 넘쳤다. 부모가 남겨 준 높이를 그대로 채우면 폭이 얼마든
/// 어긋나지 않는다.
///
/// 전체 화면 라이브에서는 부모가 높이를 정해 주지 않으므로 16:9를 유지한다.
class _LiveSurfaceBox extends StatelessWidget {
  const _LiveSurfaceBox({required this.houseMode, required this.child});

  final bool houseMode;
  final Widget child;

  @override
  Widget build(BuildContext context) => houseMode
      ? Expanded(child: child)
      : AspectRatio(aspectRatio: 16 / 9, child: child);
}
