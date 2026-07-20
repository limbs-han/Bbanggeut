import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
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
  String? error;
  bool closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    try {
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

  Future<void> _heartbeat() async {
    final current = session;
    if (current == null || closing) {
      return;
    }
    try {
      await widget.controller.api.heartbeatStream(current.id);
    } catch (_) {}
  }

  Future<void> _checkStatus() async {
    final current = session;
    if (current == null || closing) {
      return;
    }
    try {
      final updated = await widget.controller.api.getStream(current.id);
      if (!mounted) return;
      setState(() => session = updated);
      if (updated.isReady && player == null) {
        pollTimer?.cancel();
        final next = VideoPlayerController.networkUrl(
          Uri.parse(updated.playUrl!),
        );
        await next.initialize();
        await next.play();
        if (!mounted) {
          await next.dispose();
          return;
        }
        setState(() => player = next);
      } else if (const {
        'FAILED',
        'CLOSED',
        'EXPIRED',
      }.contains(updated.status)) {
        pollTimer?.cancel();
        heartbeatTimer?.cancel();
        setState(() => error = updated.failureCode ?? '라이브 세션이 종료됐어요.');
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
  }

  Future<void> _close() async {
    if (closing) return;
    closing = true;
    pollTimer?.cancel();
    heartbeatTimer?.cancel();
    final current = session;
    if (current != null) {
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
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (_, _) => _close(),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('실시간 보기'),
        actions: [
          const Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: StatusPill(label: 'LIVE')),
          ),
        ],
      ),
      body: SafeArea(
        child: PagePadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.videocam_rounded, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    widget.device.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  Text(
                    session?.status ?? '연결 중',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AspectRatio(
                aspectRatio: 16 / 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: ColoredBox(color: AppColors.ink, child: _videoBody()),
                ),
              ),
              const SizedBox(height: 16),
              if (player != null)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() {
                          player!.setVolume(player!.value.volume == 0 ? 1 : 0);
                        }),
                        icon: Icon(
                          player!.value.volume == 0
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                        ),
                        label: Text(
                          player!.value.volume == 0 ? '소리 켜기' : '소리 끄기',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.fullscreen_rounded),
                        label: const Text('전체 화면'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 18),
              Card(
                color: AppColors.mint,
                child: const Padding(
                  padding: EdgeInsets.all(18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_rounded, color: AppColors.primaryDark),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '가족에게만 안전하게 연결돼요',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppColors.primaryDark,
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              '화면을 나가면 시청 세션이 종료되고 기기 송출도 자동으로 정리됩니다.',
                              style: TextStyle(
                                height: 1.4,
                                color: AppColors.primaryDark,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _videoBody() {
    if (error != null) {
      return EmptyState(
        icon: Icons.signal_wifi_connected_no_internet_4_rounded,
        title: '라이브를 열지 못했어요',
        message: error!,
      );
    }
    if (player == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: AppColors.peach),
          const SizedBox(height: 18),
          Text(
            session?.status == 'PENDING'
                ? '카메라의 응답을 기다리고 있어요'
                : '안전한 연결을 준비하고 있어요',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: player!.value.aspectRatio,
        child: VideoPlayer(player!),
      ),
    );
  }
}
