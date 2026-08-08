/// "이 영상을 분석하고 있어요" 띠.
///
/// **왜 화면에 보여야 하나**: 분석은 영상 하나에 십수 초가 걸리고, 그동안 AI 자동
/// 컷·줌은 규칙 기반으로만 돌고 만화는 프레임을 등분해서 뽑는다. 즉 결과가
/// 달라지는데 화면에는 아무 표시가 없어서, 사용자는 "AI가 원래 이 정도인가" 하고
/// 그 결과를 받아들였다. 진행 중임을 알면 잠깐 기다렸다 다시 누를 수 있다.
///
/// 상태는 백엔드가 들고 있다(V46 `video_analyses`). 편집 워커의 메모리만 보던
/// 동안에는 워커를 재배포하면 진행 중이던 분석이 사라져 보였다.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';

/// 분석 상태를 따라가며 [builder]로 그린다. 끝나면 더 묻지 않는다.
///
/// 폴링은 화면이 열려 있는 동안만 돈다 — 닫히면 [dispose]가 멈춘다. 끝난 뒤에는
/// 더 묻지 않는다(분석은 한 번 끝나면 되돌아가지 않는다).
///
/// **그리는 모양은 화면마다 다르다.** 만화 화면은 띠([AnalysisNotice])로,
/// 편집 화면은 AI 컷 옆 숫자 하나로 보여 준다 — 편집 화면은 위에 띠가 깔리면
/// 가뜩이나 좁은 세로를 한 번 더 빼앗겼다. 따라가는 방법은 하나로 두고
/// 보여 주는 방법만 갈라 놓는다.
class AnalysisWatcher extends StatefulWidget {
  const AnalysisWatcher({
    super.key,
    required this.api,
    required this.videoId,
    required this.builder,
    this.onDone,
    this.interval = const Duration(seconds: 3),
  });

  final ApiClient api;
  final String videoId;

  final Widget Function(BuildContext context, VideoAnalysis analysis) builder;

  /// 분석이 방금 끝났다. 화면이 추천을 다시 받을 기회다.
  final VoidCallback? onDone;

  final Duration interval;

  @override
  State<AnalysisWatcher> createState() => _AnalysisWatcherState();
}

/// 분석 상태를 따라가며 [AnalysisNotice] 띠를 그린다. 끝나면 스스로 사라진다.
class AnalysisNoticeBar extends StatelessWidget {
  const AnalysisNoticeBar({
    super.key,
    required this.api,
    required this.videoId,
    this.onDone,
    this.interval = const Duration(seconds: 3),
  });

  final ApiClient api;
  final String videoId;
  final VoidCallback? onDone;
  final Duration interval;

  @override
  Widget build(BuildContext context) => AnalysisWatcher(
    api: api,
    videoId: videoId,
    onDone: onDone,
    interval: interval,
    builder: (context, analysis) => AnalysisNotice(analysis: analysis),
  );
}

class _AnalysisWatcherState extends State<AnalysisWatcher> {
  VideoAnalysis _analysis = VideoAnalysis.none;
  Timer? _timer;

  /// 겹쳐 묻지 않는다. 느린 망에서 3초 타이머가 계속 도는 동안 요청이 쌓이면
  /// 화면을 나갈 때까지 왕복이 불어난다.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    VideoAnalysis next;
    try {
      next = await widget.api.videoAnalysis(widget.videoId);
    } catch (_) {
      // 상태를 못 물어본 것은 분석이 없다는 뜻이 아니다. 띠를 지우지 않고
      // 다음 차례에 다시 묻는다.
      _busy = false;
      _schedule();
      return;
    }
    _busy = false;
    if (!mounted) return;
    final wasRunning = _analysis.isRunning;
    setState(() => _analysis = next);
    if (next.isRunning) {
      _schedule();
      return;
    }
    // 진행 중이었다가 끝났을 때만 알린다 — 화면에 들어온 순간 이미 DONE이었던
    // 영상까지 알리면 추천을 괜히 다시 받는다.
    if (wasRunning && next.isDone) widget.onDone?.call();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(widget.interval, _poll);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _analysis);
}

/// 상태 하나를 띠 하나로. 진행 중도 실패도 아니면 아무것도 그리지 않는다.
class AnalysisNotice extends StatelessWidget {
  const AnalysisNotice({super.key, required this.analysis});

  final VideoAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    if (analysis.isRunning) {
      final percent = analysis.percent;
      return _Band(
        key: const ValueKey('analysis-running'),
        color: AppColors.yellowSoft,
        leading: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: percent == null ? null : percent / 100,
          ),
        ),
        text: percent == null
            ? 'AI가 영상을 살펴보는 중이에요 · ${analysis.stageLabel}'
            : 'AI가 영상을 살펴보는 중이에요 · ${analysis.stageLabel} $percent%',
        hint: '다 되면 자동 컷과 줌, 만화 장면이 더 잘 맞아요.',
      );
    }
    if (analysis.isFailed) {
      return _Band(
        key: const ValueKey('analysis-failed'),
        color: AppColors.coralSoft,
        leading: const Icon(
          Icons.error_outline_rounded,
          size: 16,
          color: AppColors.coralDark,
        ),
        text: 'AI가 영상을 살펴보지 못했어요',
        hint: '자동 컷과 줌은 기본 규칙으로 만들어요.',
      );
    }
    return const SizedBox.shrink();
  }
}

class _Band extends StatelessWidget {
  const _Band({
    super.key,
    required this.color,
    required this.leading,
    required this.text,
    required this.hint,
  });

  final Color color;
  final Widget leading;
  final String text;
  final String hint;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: color,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: leading),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.inkSoft,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
