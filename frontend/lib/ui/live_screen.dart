import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'extra_screens.dart';
import 'widgets.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.controller, required this.device});
  final AppController controller;
  final DeviceSummary device;
  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> with WidgetsBindingObserver {
  StreamSession? session;
  VideoPlayerController? player;
  Timer? pollTimer;
  Timer? heartbeatTimer;
  Timer? tokenRefreshTimer;
  String? currentPlayUrl;
  String? error;
  bool closing = false;
  bool muted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    try {
      if (devHomeCam && devHlsUrl.isNotEmpty) {
        await _openPlayer(devHlsUrl);
        return;
      }
      session = await widget.controller.api.createStream(widget.device.id);
      if (!mounted) return;
      setState(() {});
      heartbeatTimer = Timer.periodic(
        Duration(seconds: session!.heartbeatIntervalSeconds),
        (_) => _heartbeat(),
      );
      await _checkStatus();
      pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _checkStatus(),
      );
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
  }

  Future<void> _openPlayer(String url, {bool replace = false}) async {
    if (!replace && currentPlayUrl == url && player != null) return;
    final next = VideoPlayerController.networkUrl(Uri.parse(url));
    await next.initialize();
    await next.setVolume(muted ? 0 : 1);
    await next.play();
    if (!mounted) {
      await next.dispose();
      return;
    }
    final old = player;
    setState(() {
      player = next;
      currentPlayUrl = url;
      error = null;
    });
    await old?.dispose();
  }

  Future<void> _heartbeat() async {
    final current = session;
    if (current == null || closing) return;
    try {
      await widget.controller.api.heartbeatStream(current.id);
    } catch (_) {
      // The status poll will expose terminal state; a transient heartbeat error
      // must not blank a currently playing stream.
    }
  }

  Future<void> _checkStatus() async {
    final current = session;
    if (current == null || closing) return;
    try {
      final updated = await widget.controller.api.getStream(current.id);
      if (!mounted) return;
      setState(() => session = updated);
      if (updated.isReady) {
        pollTimer?.cancel();
        await _openPlayer(updated.playUrl!);
        tokenRefreshTimer ??= Timer.periodic(
          const Duration(seconds: 20),
          (_) => _refreshPlaybackToken(),
        );
      } else if (const {
        'FAILED',
        'CLOSED',
        'EXPIRED',
      }.contains(updated.status)) {
        _cancelTimers();
        setState(() => error = updated.failureCode ?? '라이브 세션이 종료됐어요.');
      }
    } catch (failure) {
      if (mounted && player == null) setState(() => error = '$failure');
    }
  }

  Future<void> _refreshPlaybackToken() async {
    final current = session;
    if (current == null || closing) return;
    try {
      final updated = await widget.controller.api.getStream(current.id);
      if (!mounted) return;
      session = updated;
      if (updated.isReady && updated.playUrl != null) {
        // Backend live JWT expires after 30 seconds. Recreating the network
        // source every 20 seconds keeps Nginx playlist/segment auth valid.
        await _openPlayer(updated.playUrl!, replace: true);
      }
    } catch (_) {}
  }

  void _cancelTimers() {
    pollTimer?.cancel();
    heartbeatTimer?.cancel();
    tokenRefreshTimer?.cancel();
  }

  Future<void> _close() async {
    if (closing) return;
    closing = true;
    _cancelTimers();
    final current = session;
    if (current != null && !(devHomeCam && devHlsUrl.isNotEmpty)) {
      try {
        await widget.controller.api.closeStream(current.id);
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _close();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close();
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.controller.deviceStatus;
    return PopScope(
      onPopInvokedWithResult: (_, _) => _close(),
      child: Scaffold(
        body: AppBackdrop(
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.greenCard,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.eco_outlined,
                        color: AppColors.sageDark,
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.device.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            status?.isOnline == true
                                ? '● 온라인 · 안전하게 연결됨'
                                : '● 연결 준비 중',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: status?.isOnline == true
                                      ? AppColors.sageDark
                                      : AppColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                    RoundIconButton(
                      icon: Icons.notifications_none_rounded,
                      badge: false,
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NotificationsScreen(
                            controller: widget.controller,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '● H O M E  C A M  ·  L I V E',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.4,
                        color: AppColors.muted,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '우리 집 라이브 스트리밍',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SoftCard(
                  padding: EdgeInsets.zero,
                  borderColor: Colors.transparent,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            AspectRatio(
                              aspectRatio: 16 / 9,
                              child: _videoBody(),
                            ),
                            Positioned(
                              left: 12,
                              top: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xB32D312B),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: const Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 4,
                                      backgroundColor: AppColors.live,
                                    ),
                                    SizedBox(width: 7),
                                    Text(
                                      'LIVE',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              top: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 13,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xA82D312B),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: const Text(
                                  '1080p',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 12,
                              bottom: 12,
                              child: FilledButton.icon(
                                onPressed: () {
                                  setState(() => muted = !muted);
                                  player?.setVolume(muted ? 0 : 1);
                                },
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 42),
                                  backgroundColor: const Color(0x9B2D312B),
                                  foregroundColor: Colors.white,
                                ),
                                icon: Icon(
                                  muted
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                ),
                                label: Text(muted ? '소리 꺼짐' : '소리 켜짐'),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: CircleAvatar(
                                radius: 25,
                                backgroundColor: const Color(0xA82D312B),
                                child: IconButton(
                                  onPressed: player == null
                                      ? null
                                      : () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => FullscreenLiveView(
                                              controller: player!,
                                              title: widget.device.name,
                                            ),
                                          ),
                                        ),
                                  icon: const Icon(
                                    Icons.fullscreen_rounded,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
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
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    Text(
                                      status?.personCount == null
                                          ? '● 온라인 · 감지 인원 확인 중'
                                          : '● 온라인 · 가족 ${status!.personCount}명 감지',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                              const StatusPill(
                                label: 'LIVE',
                                color: AppColors.greenCard,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                const SectionHeader('오늘의 기록'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _LiveStat(
                        label: '오늘 웃음',
                        value:
                            '${widget.controller.videoStats?.byTriggerType['LAUGHTER'] ?? 0}회',
                        color: AppColors.yellowSoft,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _LiveStat(
                        label: '자동 저장',
                        value:
                            '${widget.controller.homeSummary?.savedCount ?? 0}개',
                        color: AppColors.greenCard,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _LiveStat(
                        label: '작성한 메모',
                        value:
                            '${widget.controller.homeSummary?.memoCount ?? 0}개',
                        color: AppColors.pink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const SectionHeader('다가오는 기념일'),
                const SizedBox(height: 9),
                const SoftCard(
                  borderColor: AppColors.yellow,
                  padding: EdgeInsets.all(13),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 27,
                        backgroundColor: AppColors.yellowSoft,
                        child: Text(
                          '23\nJUL',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '엄마 생일',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              '수요일 · 3일 뒤',
                              style: TextStyle(color: AppColors.muted),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const SectionHeader('최근 저장된 추억'),
                const SizedBox(height: 9),
                SoftCard(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 80,
                        child: FamilyReferenceImage(borderRadius: 13),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.controller.videos.firstOrNull?.title ??
                                  '저녁 식탁의 웃음',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              widget.controller.videos.firstOrNull == null
                                  ? '저장된 영상이 아직 없어요'
                                  : memoryDate(
                                      widget
                                          .controller
                                          .videos
                                          .first
                                          .capturedStartAt,
                                    ),
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.add_rounded,
                        size: 30,
                        color: AppColors.muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _videoBody() {
    if (player != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: player!.value.aspectRatio,
            child: VideoPlayer(player!),
          ),
        ),
      );
    }
    return ColoredBox(
      color: const Color(0xFF171A18),
      child: Center(
        child: error == null
            ? const CircularProgressIndicator(color: Colors.white)
            : Padding(
                padding: const EdgeInsets.all(28),
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

class _LiveStat extends StatelessWidget {
  const _LiveStat({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    height: 74,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.inkSoft,
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
        ),
      ],
    ),
  );
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class EmbeddedLivePlayer extends StatefulWidget {
  const EmbeddedLivePlayer({
    super.key,
    required this.controller,
    required this.device,
    required this.status,
  });

  final AppController controller;
  final DeviceSummary device;
  final DeviceStatus? status;

  @override
  State<EmbeddedLivePlayer> createState() => _EmbeddedLivePlayerState();
}

class _EmbeddedLivePlayerState extends State<EmbeddedLivePlayer>
    with WidgetsBindingObserver {
  StreamSession? session;
  VideoPlayerController? player;
  late final ValueNotifier<VideoPlayerController?> playerListenable;
  Timer? pollTimer;
  Timer? heartbeatTimer;
  Timer? tokenRefreshTimer;
  String? currentPlayUrl;
  String? error;
  bool closing = false;
  bool muted = true;

  @override
  void initState() {
    super.initState();
    playerListenable = ValueNotifier(null);
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didUpdateWidget(covariant EmbeddedLivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id) {
      unawaited(_restart());
    } else if (oldWidget.status?.isOnline == false &&
        widget.status?.isOnline == true &&
        player == null) {
      unawaited(_restart());
    }
  }

  Future<void> _start() async {
    if (widget.status?.isOnline == false &&
        !(devHomeCam && devHlsUrl.isNotEmpty)) {
      if (mounted) setState(() => error = '카메라가 오프라인이에요.');
      return;
    }
    try {
      if (devHomeCam && devHlsUrl.isNotEmpty) {
        await _openPlayer(devHlsUrl);
        return;
      }
      session = await widget.controller.api.createStream(widget.device.id);
      if (!mounted || closing) return;
      heartbeatTimer = Timer.periodic(
        Duration(seconds: session!.heartbeatIntervalSeconds),
        (_) => _heartbeat(),
      );
      await _checkStatus();
      pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _checkStatus(),
      );
    } catch (failure) {
      if (mounted && !closing) setState(() => error = '$failure');
    }
  }

  Future<void> _openPlayer(String url, {bool replace = false}) async {
    if (!replace && currentPlayUrl == url && player != null) return;
    final next = VideoPlayerController.networkUrl(Uri.parse(url));
    await next.initialize();
    await next.setVolume(muted ? 0 : 1);
    await next.play();
    if (!mounted || closing) {
      await next.dispose();
      return;
    }
    final old = player;
    setState(() {
      player = next;
      playerListenable.value = next;
      currentPlayUrl = url;
      error = null;
    });
    await old?.dispose();
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
        await _openPlayer(updated.playUrl!);
        tokenRefreshTimer ??= Timer.periodic(
          const Duration(seconds: 20),
          (_) => _refreshPlaybackToken(),
        );
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
      if (mounted && player == null && !closing) {
        setState(() => error = '$failure');
      }
    }
  }

  Future<void> _refreshPlaybackToken() async {
    final current = session;
    if (current == null || closing) return;
    try {
      final updated = await widget.controller.api.getStream(current.id);
      if (!mounted || closing) return;
      session = updated;
      if (updated.isReady && updated.playUrl != null) {
        await _openPlayer(updated.playUrl!, replace: true);
      }
    } catch (_) {}
  }

  void _cancelTimers() {
    pollTimer?.cancel();
    heartbeatTimer?.cancel();
    tokenRefreshTimer?.cancel();
    pollTimer = null;
    heartbeatTimer = null;
    tokenRefreshTimer = null;
  }

  Future<void> _close({bool disposePlayer = false}) async {
    if (closing) return;
    closing = true;
    _cancelTimers();
    final current = session;
    session = null;
    if (disposePlayer) {
      final currentPlayer = player;
      player = null;
      playerListenable.value = null;
      currentPlayUrl = null;
      await currentPlayer?.dispose();
    }
    if (current != null && !(devHomeCam && devHlsUrl.isNotEmpty)) {
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
      error = null;
    });
    await _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_close(disposePlayer: true));
    } else if (state == AppLifecycleState.resumed && closing) {
      unawaited(_restart());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close(disposePlayer: true));
    playerListenable.dispose();
    super.dispose();
  }

  Future<void> _openFullscreen() async {
    final current = player;
    if (current == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenLiveView(
          controller: current,
          controllerListenable: playerListenable,
          title: widget.device.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    radius: 24,
    borderColor: Colors.transparent,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _videoBody(),
                Positioned(
                  left: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xB32D312B),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: const Text(
                      '●  LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                if (player != null) ...[
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0x99000000),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        setState(() => muted = !muted);
                        player?.setVolume(muted ? 0 : 1);
                      },
                      icon: Icon(
                        muted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0x99000000),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _openFullscreen,
                      icon: const Icon(Icons.fullscreen_rounded),
                    ),
                  ),
                ],
              ],
            ),
          ),
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
    final current = player;
    if (current != null) {
      return ColoredBox(
        color: Colors.black,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: current.value.size.width,
            height: current.value.size.height,
            child: VideoPlayer(current),
          ),
        ),
      );
    }
    return ColoredBox(
      color: const Color(0xFF171A18),
      child: Center(
        child: error == null
            ? const CircularProgressIndicator(color: Colors.white)
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

class FullscreenLiveView extends StatefulWidget {
  const FullscreenLiveView({
    super.key,
    required this.controller,
    required this.title,
    this.controllerListenable,
  });
  final VideoPlayerController controller;
  final ValueListenable<VideoPlayerController?>? controllerListenable;
  final String title;

  @override
  State<FullscreenLiveView> createState() => _FullscreenLiveViewState();
}

class _FullscreenLiveViewState extends State<FullscreenLiveView> {
  late VideoPlayerController activeController;
  bool controlsVisible = true;
  Timer? controlsTimer;

  @override
  void initState() {
    super.initState();
    activeController = widget.controllerListenable?.value ?? widget.controller;
    activeController.addListener(_refresh);
    widget.controllerListenable?.addListener(_replaceController);
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

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _replaceController() {
    final next = widget.controllerListenable?.value;
    if (next == null || identical(next, activeController)) return;
    activeController.removeListener(_refresh);
    activeController = next;
    activeController.addListener(_refresh);
    _refresh();
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => controlsVisible = !controlsVisible);
    if (controlsVisible) _scheduleControlsHide();
  }

  @override
  void dispose() {
    controlsTimer?.cancel();
    widget.controllerListenable?.removeListener(_replaceController);
    activeController.removeListener(_refresh);
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = activeController.value;
    final videoWidth = value.size.width > 0 ? value.size.width : 1600.0;
    final videoHeight = value.size.height > 0 ? value.size.height : 900.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: videoWidth,
                height: videoHeight,
                child: VideoPlayer(activeController),
              ),
            ),
            AnimatedOpacity(
              opacity: controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !controlsVisible,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x99000000),
                        Colors.transparent,
                        Colors.transparent,
                        Color(0xB3000000),
                      ],
                      stops: [0, .22, .65, 1],
                    ),
                  ),
                  child: SafeArea(
                    child: Stack(
                      children: [
                        Positioned(
                          top: 8,
                          left: 8,
                          right: 8,
                          child: Row(
                            children: [
                              IconButton.filled(
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0x99000000),
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(
                                  Icons.close_fullscreen_rounded,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xB3D32F2F),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: const Text(
                                  '●  LIVE',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
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
                            ],
                          ),
                        ),
                        Center(
                          child: IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0x99000000),
                              foregroundColor: Colors.white,
                              minimumSize: const Size.square(76),
                            ),
                            onPressed: () {
                              value.isPlaying
                                  ? activeController.pause()
                                  : activeController.play();
                              _scheduleControlsHide();
                            },
                            iconSize: 42,
                            icon: Icon(
                              value.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                        ),
                        const Positioned(
                          left: 20,
                          bottom: 16,
                          child: Text(
                            '실시간 홈캠 영상',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
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
}
