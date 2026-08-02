/// 아이폰 사진 앱의 영상 편집을 그대로 옮긴 구간 설정 막대.
///
/// **왜 새로 만들었나**: 예전 타임라인은 "잘라낸 뒤의 길이"를 폭 전체에 펼쳐
/// 그렸다. 그래서 시작 손잡이를 오른쪽으로 끌면 클립이 짧아지고, 짧아진 만큼
/// 눈금 배율이 커져서 손잡이가 손가락에서 달아났다 — 구간이 아예 잡히지
/// 않았던 진짜 이유다.
///
/// 여기서는 띠가 언제나 **원본 전체**를 담는다. 배율이 드래그 중에 바뀌지
/// 않으므로 손잡이가 손끝에 붙어 움직이고, 노란 창 밖은 그대로 "잘려 나갈
/// 부분"으로 흐리게 남는다. 창을 다시 넓히면 잘랐던 앞뒤가 되살아난다.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_tokens.dart';
import 'editor_project.dart';

abstract final class TrimBarTokens {
  /// 프레임이 아직 안 왔을 때만 잠깐 보이는 바닥색.
  static const track = Color(0xFF2B2622);
  static const handle = Color(0xFFF5C518);
  static const handleInk = Color(0xFF1B1B1B);

  /// 구간 밖을 덮는 막. 그림은 비치되 "여기는 빠진다"가 한눈에 보인다.
  static const outside = Color(0x9EF3EFEA);

  /// 달라붙은 손잡이. 붙었다는 걸 손끝뿐 아니라 눈으로도 알 수 있어야 한다.
  static const handleSnapped = Color(0xFFFFE45C);

  static const handleWidth = 22.0;
  static const handleTouchWidth = 44.0;
  static const frameBar = 4.0;

  /// 고른 구간이 이보다 좁아 보이지는 않게 한다.
  ///
  /// 예전에는 손잡이 둘이 구간 **안**에 있어서 이 값이 손잡이 폭의 두 배
  /// (52px)여야 했다. 2분짜리 영상에서 그건 20초다 — 그보다 짧게 자를 수가
  /// 없었다. 손잡이를 밖으로 내보낸 지금은 서로 덮을 일이 없으니, 두 손잡이가
  /// 붙어 보이지 않을 만큼만 남기면 된다.
  static const minimumWindow = 8.0;

  /// 이만큼 가까우면 손잡이가 그 자리에 달라붙는다.
  static const snapDistance = 12.0;
}

class TrimRangeBar extends StatefulWidget {
  const TrimRangeBar({
    super.key,
    required this.sourceDurationMs,
    required this.startMs,
    required this.endMs,
    required this.playheadSourceMs,
    required this.thumbnails,
    required this.minimumDurationMs,
    required this.onTrimChanged,
    required this.onTrimCommitted,
    required this.onScrub,
    this.interactive = true,
    this.lowerBoundMs,
    this.upperBoundMs,
    this.windowSlidable = false,
    this.zoomSegments = const [],
  });

  /// 띠가 담는 전체 길이. 드래그 중에도 절대 바뀌지 않는다.
  final int sourceDurationMs;

  /// 지금 고른 구간.
  final int startMs;
  final int endMs;

  /// 재생 위치(원본 기준).
  final int playheadSourceMs;

  /// 원본 전체에 걸쳐 고르게 뽑은 프레임들.
  final List<String> thumbnails;

  final int minimumDurationMs;

  /// 손잡이를 끄는 동안 계속 불린다. 이력에 쌓지 않는 "미리보기" 갱신이다.
  /// [startHandle]은 지금 잡고 있는 손잡이가 앞쪽인지 — 미리보기를 그 프레임에
  /// 맞춰 보여 주는 데 쓴다.
  final void Function(int startMs, int endMs, bool startHandle) onTrimChanged;

  /// 손가락을 뗐다. 여기서 한 번만 되돌리기 이력에 쌓는다.
  final VoidCallback onTrimCommitted;

  /// 띠를 눌러 재생 위치를 옮겼다(원본 기준 시각).
  final ValueChanged<int> onScrub;

  /// false면 보기 전용이다. 다른 탭에서 "지금 구간"을 보여줄 때 쓴다.
  final bool interactive;

  /// 창이 넘어갈 수 없는 경계. 줌처럼 서로 겹치면 안 되는 구간이 이웃
  /// 구간의 끝·시작을 넘겨 준다. null이면 영상의 처음·끝이 경계다.
  final int? lowerBoundMs;
  final int? upperBoundMs;

  /// 노란 창 안쪽을 끌면 구간 전체가 길이를 유지한 채 옮겨지는가.
  /// 줌·자막처럼 "구간을 통째로 옮기는" 편집에서 켠다.
  final bool windowSlidable;
  final List<EditorZoomSegment> zoomSegments;

  @override
  State<TrimRangeBar> createState() => _TrimRangeBarState();
}

class _TrimRangeBarState extends State<TrimRangeBar> {
  static const _frameRate = 30;

  /// 드래그 중에만 채워진다. 부모에게 알리지 않고도 손잡이가 손가락을 따라
  /// 움직이게 하는 값이다.
  int? _liveStartMs;
  int? _liveEndMs;
  bool _draggingStart = false;
  bool _draggingEnd = false;

  int _anchorMs = 0;
  double _travelPx = 0;
  double _msPerPx = 1;
  double _timelineScale = 1;
  double _pinchStartScale = 1;
  int _scrubAnchorMs = 0;
  double _scrubTravelPx = 0;

  /// 지금 손잡이가 달라붙어 있는 자리. 없으면 null.
  int? _snappedMs;

  /// 창 통째 끌기 중인가.
  bool _slidingWindow = false;
  double _slideTravelPx = 0;
  int _slideAnchorStartMs = 0;
  int _slideDurationMs = 0;

  bool get _dragging => _draggingStart || _draggingEnd || _slidingWindow;

  int get _startMs => _liveStartMs ?? widget.startMs;
  int get _endMs => _liveEndMs ?? widget.endMs;

  int get _lowerBoundMs => widget.lowerBoundMs ?? 0;
  int get _upperBoundMs => widget.upperBoundMs ?? widget.sourceDurationMs;

  @override
  void didUpdateWidget(TrimRangeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 밖에서 값이 바뀌었는데(되돌리기 등) 드래그 중이 아니면 그대로 따라간다.
    if (!_dragging) {
      _liveStartMs = null;
      _liveEndMs = null;
    }
  }

  /// 띠는 프레임으로만 채운다.
  ///
  /// 예전에는 둥근 회색 통 안에 재생 버튼과 여백을 두고 그 안쪽에만 프레임을
  /// 깔았다. 정작 봐야 할 그림이 가장자리에서 잘려 어디를 자르는지 가늠하기
  /// 어려웠다. 재생은 미리보기 위 버튼이 이미 맡고 있다.
  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 26,
        child: ColoredBox(
          color: const Color(0xFF15171C),
          child: Row(
            children: [
              const SizedBox(width: 8),
              const Text(
                '프레임 타임라인',
                style: TextStyle(
                  color: Color(0xFFAEB4C0),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const Text(
                '핀치로 확대',
                style: TextStyle(color: Color(0xFF747B89), fontSize: 9),
              ),
              const SizedBox(width: 6),
              _TimelineZoomControls(
                scale: _timelineScale,
                onZoomOut: _timelineScale <= 1
                    ? null
                    : () => setState(
                        () => _timelineScale = math.max(1, _timelineScale / 2),
                      ),
                onZoomIn: _timelineScale >= 8
                    ? null
                    : () => setState(
                        () => _timelineScale = math.min(8, _timelineScale * 2),
                      ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
      Expanded(child: _strip()),
    ],
  );

  Widget _strip() {
    final totalMs = math.max(1, widget.sourceDurationMs);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        // 손잡이는 고른 구간 **밖**에 선다.
        //
        // **왜 밖인가**: 예전에는 노란 창 [시작, 끝] 안쪽 양 끝에 손잡이를
        // 그렸다. 그러면 손잡이가 덮은 44px만큼의 프레임도 구간에 **들어가
        // 있는데** 눈에는 안 보인다 — 손잡이 사이에 보이는 그림과 실제로 남는
        // 구간이 어긋났고, 구간 재생을 누르면 보이지 않던 앞뒤가 함께 나왔다.
        // 이제 손잡이를 창 바깥에 세우고, 시간은 손잡이 자리를 뺀 안쪽(트랙)에만
        // 펼친다. 손잡이 사이에 보이는 그림이 곧 남는 구간이다.
        final trackLeft = TrimBarTokens.handleWidth;
        final trackWidth = math.max(1.0, width - TrimBarTokens.handleWidth * 2);
        final trackRight = trackLeft + trackWidth;
        final visibleDurationMs = math.max(
          1,
          (totalMs / _timelineScale).round(),
        );
        final maximumVisibleStart = math.max(0, totalMs - visibleDurationMs);
        final visibleStartMs =
            (widget.playheadSourceMs - visibleDurationMs ~/ 2).clamp(
              0,
              maximumVisibleStart,
            );
        final visibleEndMs = visibleStartMs + visibleDurationMs;
        final msPerPx = visibleDurationMs / trackWidth;
        const minimumWindowPx = TrimBarTokens.minimumWindow;
        final minimumMs = math.max(
          widget.minimumDurationMs,
          (minimumWindowPx * msPerPx).round(),
        );

        double xOf(int ms) =>
            trackLeft +
            ((ms - visibleStartMs) / visibleDurationMs * trackWidth).clamp(
              0.0,
              trackWidth,
            );

        bool visible(int ms) => ms >= visibleStartMs && ms <= visibleEndMs;

        var startX = xOf(_startMs);
        var endX = xOf(_endMs);
        if (endX - startX < minimumWindowPx) {
          endX = math.min(trackRight, startX + minimumWindowPx);
          startX = math.max(trackLeft, endX - minimumWindowPx);
        }
        final playheadX = xOf(widget.playheadSourceMs.clamp(_startMs, _endMs));

        return Stack(
          key: const Key('editor-timeline-strip'),
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: trackLeft,
              width: trackWidth,
              top: 0,
              bottom: 0,
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned(
                      left:
                          -(visibleStartMs / totalMs) *
                          trackWidth *
                          _timelineScale,
                      width: trackWidth * _timelineScale,
                      top: 0,
                      bottom: 0,
                      child: _FilmStrip(thumbnails: widget.thumbnails),
                    ),
                  ],
                ),
              ),
            ),
            for (final (index, zoom) in widget.zoomSegments.indexed)
              if (zoom.sourceEndMs > visibleStartMs &&
                  zoom.sourceStartMs < visibleEndMs)
                Positioned(
                  key: Key('editor-zoom-marker-${zoom.id}'),
                  left: xOf(
                    zoom.sourceStartMs.clamp(visibleStartMs, visibleEndMs),
                  ),
                  width: math.max(
                    3,
                    xOf(zoom.sourceEndMs.clamp(visibleStartMs, visibleEndMs)) -
                        xOf(
                          zoom.sourceStartMs.clamp(
                            visibleStartMs,
                            visibleEndMs,
                          ),
                        ),
                  ),
                  // 순번마다 줄(레인)을 바꿔 얹는다 — 시간이 겹치는 구간도
                  // 서로 가리지 않고 계단처럼 보인다.
                  bottom: 2 + (index % 3) * 8.0,
                  height: 7,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // 구간마다 다른 색 — 카드·칩의 순번 색과 같다.
                      color: EditorMarkerTokens.colorAt(index),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white, width: 1),
                    ),
                  ),
                ),
            // 구간 밖 — 빠지는 부분.
            _veil(left: trackLeft, width: startX - trackLeft),
            _veil(left: endX, width: trackRight - endX),
            // 어디를 눌러도 그 자리로 재생 위치가 간다. 손잡이는 이 층보다
            // 위에 있어서 드래그를 먼저 잡는다.
            Positioned(
              left: trackLeft,
              width: trackWidth,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                key: const Key('editor-timeline-scrub'),
                behavior: HitTestBehavior.translucent,
                onTapDown: (details) =>
                    _scrubAt(details.localPosition.dx, visibleStartMs, msPerPx),
                onScaleStart: (details) => _startTimelineGesture(),
                onScaleUpdate: (details) =>
                    _updateTimelineGesture(details, msPerPx),
              ),
            ),
            Positioned(
              key: const Key('editor-trim-window'),
              left: startX - TrimBarTokens.handleWidth,
              width: (endX - startX) + TrimBarTokens.handleWidth * 2,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: _TrimFrame(snapped: _snappedMs != null),
              ),
            ),
            // 노란 창 안쪽을 끌면 구간이 통째로 옮겨진다. 탭은 아래
            // 스크럽 층으로 그대로 내려간다. 창이 원본 전체를 덮고 있으면
            // 옮길 자리가 없으므로 이 층을 깔지 않는다 — 그때는 끌기가
            // 스크럽(재생 위치 이동)으로 내려간다.
            if (widget.interactive &&
                widget.windowSlidable &&
                _endMs - _startMs + 34 < _upperBoundMs - _lowerBoundMs)
              Positioned(
                key: const Key('editor-trim-window-slide'),
                left: startX,
                width: math.max(0, endX - startX),
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) => _startWindowSlide(msPerPx),
                  onHorizontalDragUpdate: (details) =>
                      _updateWindowSlide(details.delta.dx),
                  onHorizontalDragEnd: (_) => _endWindowSlide(),
                  onHorizontalDragCancel: _endWindowSlide,
                  child: const SizedBox.expand(),
                ),
              ),
            Positioned(
              left: (playheadX - _Playhead.width / 2).clamp(
                0.0,
                math.max(0.0, width - _Playhead.width),
              ),
              top: 0,
              bottom: 0,
              width: _Playhead.width,
              child: const IgnorePointer(child: _Playhead()),
            ),
            if (widget.interactive) ...[
              if (visible(_endMs))
                _handleTouchZone(
                  key: const Key('editor-trim-end-handle'),
                  centerX: endX + TrimBarTokens.handleWidth / 2,
                  width: width,
                  isStart: false,
                  msPerPx: msPerPx,
                  minimumMs: minimumMs,
                ),
              if (visible(_startMs))
                _handleTouchZone(
                  key: const Key('editor-trim-start-handle'),
                  centerX: startX - TrimBarTokens.handleWidth / 2,
                  width: width,
                  isStart: true,
                  msPerPx: msPerPx,
                  minimumMs: minimumMs,
                ),
            ],
            if (_dragging)
              Positioned(
                left: 0,
                right: 0,
                top: 4,
                child: IgnorePointer(
                  child: Center(
                    // 어느 프레임에서 자르는지까지 보여 준다(분:초:프레임).
                    child: _RangeBadge(
                      label:
                          '${frameClock(_startMs)} ~ ${frameClock(_endMs)}'
                          ' · ${_clock(_endMs - _startMs)}',
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _veil({required double left, required double width}) => Positioned(
    left: left,
    width: math.max(0, width),
    top: 0,
    bottom: 0,
    child: const IgnorePointer(child: ColoredBox(color: TrimBarTokens.outside)),
  );

  /// 손잡이 위에 얹는 투명한 손가락 판. 보이는 손잡이는 22px이지만 실제로
  /// 눌리는 자리는 44px다 — 작은 그림을 정확히 집으라고 요구하지 않는다.
  Widget _handleTouchZone({
    required Key key,
    required double centerX,
    required double width,
    required bool isStart,
    required double msPerPx,
    required int minimumMs,
  }) => Positioned(
    left: (centerX - TrimBarTokens.handleTouchWidth / 2).clamp(
      0.0,
      math.max(0.0, width - TrimBarTokens.handleTouchWidth),
    ),
    width: TrimBarTokens.handleTouchWidth,
    top: 0,
    bottom: 0,
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) =>
          _startHandleDrag(isStart: isStart, msPerPx: msPerPx),
      onHorizontalDragUpdate: (details) => _updateHandleDrag(
        deltaPx: details.delta.dx,
        isStart: isStart,
        minimumMs: minimumMs,
      ),
      onHorizontalDragEnd: (_) => _endHandleDrag(),
      onHorizontalDragCancel: _endHandleDrag,
      child: const SizedBox.expand(),
    ),
  );

  void _startHandleDrag({required bool isStart, required double msPerPx}) {
    setState(() {
      _draggingStart = isStart;
      _draggingEnd = !isStart;
      _anchorMs = isStart ? _startMs : _endMs;
      _travelPx = 0;
      _msPerPx = msPerPx;
      _snappedMs = null;
      _liveStartMs = _startMs;
      _liveEndMs = _endMs;
    });
  }

  void _updateHandleDrag({
    required double deltaPx,
    required bool isStart,
    required int minimumMs,
  }) {
    if (!_dragging) return;
    _travelPx += deltaPx;
    final raw = _frameAligned((_anchorMs + _travelPx * _msPerPx).round());
    final value = _snapped(raw);
    setState(() {
      if (isStart) {
        _liveStartMs = value.clamp(_lowerBoundMs, _endMs - minimumMs);
      } else {
        _liveEndMs = value.clamp(_startMs + minimumMs, _upperBoundMs);
      }
    });
    widget.onTrimChanged(_startMs, _endMs, isStart);
  }

  void _startWindowSlide(double msPerPx) {
    setState(() {
      _slidingWindow = true;
      _slideTravelPx = 0;
      _slideAnchorStartMs = _startMs;
      _slideDurationMs = _endMs - _startMs;
      _msPerPx = msPerPx;
      _snappedMs = null;
      _liveStartMs = _startMs;
      _liveEndMs = _endMs;
    });
  }

  void _updateWindowSlide(double deltaPx) {
    if (!_slidingWindow) return;
    _slideTravelPx += deltaPx;
    final int start = _frameAligned(
      (_slideAnchorStartMs + _slideTravelPx * _msPerPx).round(),
    ).clamp(
      _lowerBoundMs,
      math.max(_lowerBoundMs, _upperBoundMs - _slideDurationMs),
    );
    setState(() {
      _liveStartMs = start;
      _liveEndMs = start + _slideDurationMs;
    });
    widget.onTrimChanged(_startMs, _endMs, true);
  }

  void _endWindowSlide() {
    if (!_slidingWindow) return;
    setState(() => _slidingWindow = false);
    widget.onTrimCommitted();
  }

  /// 가까운 자리에 손잡이를 달라붙게 한다.
  ///
  /// **왜 필요한가**: 1px이 몇백 ms다(2분짜리 영상, 340px 띠에서 약 390ms).
  /// "영상 처음부터"나 "흰 선까지 딱"은 아주 흔한 요구인데, 손가락으로 그
  /// 한 점을 맞히는 건 사실상 불가능하다. 늘 몇백 ms가 남거나 넘친다.
  ///
  /// 달라붙는 자리는 셋이다 — 영상의 **처음**, **끝**, 그리고 지금 **재생
  /// 위치**(흰 선). 붙는 순간 짧게 떨리고 손잡이가 밝아진다.
  int _snapped(int rawMs) {
    final tolerance = (TrimBarTokens.snapDistance * _msPerPx).round();
    var best = rawMs;
    var bestDistance = tolerance + 1;
    for (final target in <int>[
      _lowerBoundMs,
      _upperBoundMs,
      widget.playheadSourceMs,
      for (final zoom in widget.zoomSegments) ...[
        zoom.sourceStartMs,
        zoom.sourceEndMs,
      ],
    ]) {
      final distance = (target - rawMs).abs();
      if (distance <= tolerance && distance < bestDistance) {
        best = target;
        bestDistance = distance;
      }
    }
    final landed = bestDistance <= tolerance ? best : null;
    if (landed != _snappedMs) {
      _snappedMs = landed;
      if (landed != null) unawaited(HapticFeedback.selectionClick());
    }
    return best;
  }

  int _frameAligned(int milliseconds) {
    final frame = (milliseconds * _frameRate / 1000).round();
    return (frame * 1000 / _frameRate).round().clamp(
      0,
      widget.sourceDurationMs,
    );
  }

  void _endHandleDrag() {
    if (!_dragging) return;
    setState(() {
      _draggingStart = false;
      _draggingEnd = false;
      _snappedMs = null;
    });
    widget.onTrimCommitted();
  }

  void _scrubAt(double dx, int visibleStartMs, double msPerPx) {
    final sourceMs = _frameAligned(
      visibleStartMs + (dx * msPerPx).round(),
    ).clamp(_startMs, _endMs);
    widget.onScrub(sourceMs);
  }

  void _startTimelineGesture() {
    _pinchStartScale = _timelineScale;
    _scrubAnchorMs = widget.playheadSourceMs;
    _scrubTravelPx = 0;
  }

  void _updateTimelineGesture(ScaleUpdateDetails details, double msPerPx) {
    if (details.pointerCount >= 2) {
      setState(() {
        _timelineScale = (_pinchStartScale * details.scale).clamp(1.0, 8.0);
      });
      return;
    }
    _scrubTravelPx += details.focalPointDelta.dx;
    // 손가락이 간 방향으로 재생 위치도 간다. 예전에는 "필름을 끌어온다"는
    // 셈으로 부호를 뒤집었는데, 띠가 화면에 고정돼 있으니 눌러 옮기는 것과
    // 끌어 옮기는 것이 반대로 움직여 어느 쪽도 믿을 수 없었다.
    final sourceMs = _frameAligned(
      (_scrubAnchorMs + _scrubTravelPx * msPerPx).round(),
    ).clamp(_startMs, _endMs);
    widget.onScrub(sourceMs);
  }
}

class _TimelineZoomControls extends StatelessWidget {
  const _TimelineZoomControls({
    required this.scale,
    required this.onZoomOut,
    required this.onZoomIn,
  });

  final double scale;
  final VoidCallback? onZoomOut;
  final VoidCallback? onZoomIn;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xD91D1916),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(
          key: const Key('editor-timeline-zoom-out'),
          icon: Icons.remove_rounded,
          onTap: onZoomOut,
        ),
        Text(
          '${scale.toStringAsFixed(scale == scale.roundToDouble() ? 0 : 1)}×',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w900,
          ),
        ),
        _button(
          key: const Key('editor-timeline-zoom-in'),
          icon: Icons.add_rounded,
          onTap: onZoomIn,
        ),
      ],
    ),
  );

  Widget _button({
    required Key key,
    required IconData icon,
    required VoidCallback? onTap,
  }) => IconButton(
    key: key,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 26, height: 26),
    padding: EdgeInsets.zero,
    onPressed: onTap,
    icon: Icon(
      icon,
      size: 16,
      color: onTap == null ? Colors.white30 : Colors.white,
    ),
  );
}

/// 재생 위치 표시선.
///
/// **왜 위에 손잡이 머리를 붙였나**: 예전에는 3px 흰 선 하나였다. 구간을 정하면
/// 그 선이 시작 손잡이 자리에 그대로 겹쳐 붙어, 아예 안 보이거나 노란 손잡이의
/// 일부처럼 보였다. 그래서 사용자는 이게 "옮길 수 있는 것"이라는 걸 알 수 없었고,
/// 분할이 왜 안 되는지도 알 수 없었다 — 분할은 이 선 자리에서 자른다.
class _Playhead extends StatelessWidget {
  const _Playhead();

  static const width = 12.0;
  static const _lineWidth = 3.0;

  @override
  Widget build(BuildContext context) => Stack(
    key: const Key('editor-playhead'),
    alignment: Alignment.topCenter,
    children: [
      Center(
        child: Container(
          width: _lineWidth,
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(2),
            boxShadow: const [
              BoxShadow(color: Color(0x73000000), blurRadius: 3),
            ],
          ),
        ),
      ),
      Container(
        width: width,
        height: 7,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(4)),
          boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 3)],
        ),
      ),
    ],
  );
}

/// 노란 창. 손잡이는 **창 밖** 양옆에 서고, 창 위아래에 굵은 줄이 걸린다.
/// 그래서 손잡이 사이에 맑게 보이는 그림이 곧 남는 구간이다.
class _TrimFrame extends StatelessWidget {
  const _TrimFrame({required this.snapped});

  final bool snapped;

  @override
  Widget build(BuildContext context) {
    final color = snapped ? TrimBarTokens.handleSnapped : TrimBarTokens.handle;
    return Row(
      children: [
        _FrameHandle(isStart: true, color: color),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.symmetric(
                horizontal: BorderSide(
                  color: color,
                  width: TrimBarTokens.frameBar,
                ),
              ),
            ),
            child: const SizedBox.expand(),
          ),
        ),
        _FrameHandle(isStart: false, color: color),
      ],
    );
  }
}

class _FrameHandle extends StatelessWidget {
  const _FrameHandle({required this.isStart, required this.color});

  final bool isStart;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: TrimBarTokens.handleWidth,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      // 둥근 쪽이 바깥이다 — 창을 감싸는 괄호처럼 보인다.
      borderRadius: BorderRadius.horizontal(
        left: Radius.circular(isStart ? 9 : 2),
        right: Radius.circular(isStart ? 2 : 9),
      ),
    ),
    child: Icon(
      isStart ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
      size: 20,
      color: TrimBarTokens.handleInk,
    ),
  );
}

class _FilmStrip extends StatelessWidget {
  const _FilmStrip({required this.thumbnails});

  final List<String> thumbnails;

  @override
  Widget build(BuildContext context) {
    if (thumbnails.isEmpty) {
      // 여기에 회전 표시를 두면 테스트의 pumpAndSettle이 영영 멈추지 않고,
      // 사용자에게도 "뭔가 고장 났나" 하는 인상만 준다. 조용히 비워 둔다.
      return const ColoredBox(color: EditorColorTokens.border);
    }
    return Row(
      // **왜 stretch인가**: 기본값(center)이면 Row가 세로로 헐렁한 제약을
      // 주고, 그러면 그림이 제 비율대로 줄어들어 칸 가운데에 얇은 띠로
      // 깔린다 — 위아래가 텅 비어 보이던 이유다. 늘려 주면 BoxFit.cover가
      // 칸을 남김없이 채운다.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final path in thumbnails)
          Expanded(
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: EditorColorTokens.border),
            ),
          ),
      ],
    );
  }
}

class _RangeBadge extends StatelessWidget {
  const _RangeBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xCC1E1510),
      borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

String _clock(int milliseconds) {
  final value = Duration(milliseconds: math.max(0, milliseconds));
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 분:초:프레임(30fps). 한 시간을 넘는 영상은 다루지 않으므로 시는 없다.
String frameClock(int milliseconds, {int frameRate = 30}) {
  final totalFrames = (math.max(0, milliseconds) * frameRate / 1000).round();
  final frames = totalFrames % frameRate;
  final totalSeconds = totalFrames ~/ frameRate;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds:${frames.toString().padLeft(2, '0')}';
}
