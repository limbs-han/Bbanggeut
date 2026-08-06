import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'laugh_draw_controller.dart';

/// 추억 뽑기 기계.
///
/// **왜 직접 그리는가**: 공이 유리통 안에서 돌고 튀다가 한 알만 배출구로 떨어져야
/// 하는데, 그건 이미지 한 장으로는 만들 수 없다. 그리고 이걸 위해 파티클이나
/// 물리 엔진 패키지를 들이면 프레임과 앱 크기를 그만큼 내준다. 껍데기는
/// [CustomPaint] 두 번(공 뒤·공 앞), 공은 [Container] 하나씩이고, 움직임은
/// **반복 컨트롤러 하나 + 공마다 다른 위상·속도**로 만든다.
///
/// 컨트롤러는 회전용 하나와 마무리용 하나뿐이다. 공 7개에 각자 컨트롤러를 달면
/// 매 프레임 7개가 따로 깨어나 같은 그림을 다시 그린다.
class LaughDrawMachine extends StatefulWidget {
  const LaughDrawMachine({super.key, required this.phase, this.animate = true});

  final LaughDrawPhase phase;

  /// 앱이 백그라운드로 가거나 화면이 덮이면 false. 반복 애니메이션을 멈춘다.
  final bool animate;

  @override
  State<LaughDrawMachine> createState() => _LaughDrawMachineState();
}

class _LaughDrawMachineState extends State<LaughDrawMachine>
    with TickerProviderStateMixin {
  /// 공이 한 바퀴 도는 시간.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  );

  /// 당첨 공이 떨어지는 마무리 연출. 길이는 컨트롤러의 연출 시간과 맞춘다.
  late final AnimationController _finish = AnimationController(
    vsync: this,
    duration: LaughDrawController.revealDuration,
  );

  /// 마무리가 시작된 순간의 회전 값.
  ///
  /// 당첨 공은 "돌던 그 자리에서" 배출구로 움직여야 한다. 이 값을 붙잡아 두지
  /// 않으면 공이 화면 어딘가에서 갑자기 나타난 것처럼 보인다.
  double _spinAtReveal = 0;

  bool get _spinning =>
      widget.phase == LaughDrawPhase.drawing ||
      widget.phase == LaughDrawPhase.revealing;

  @override
  void initState() {
    super.initState();
    _syncAnimations();
  }

  @override
  void didUpdateWidget(LaughDrawMachine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase ||
        oldWidget.animate != widget.animate) {
      _syncAnimations();
    }
  }

  void _syncAnimations() {
    if (_spinning && widget.animate) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      _spin.stop();
    }

    if (widget.phase == LaughDrawPhase.revealing) {
      if (_finish.status == AnimationStatus.dismissed) {
        _spinAtReveal = _spin.value;
        if (widget.animate) {
          _finish.forward();
        } else {
          _finish.value = 1;
        }
      }
    } else if (_finish.value != 0) {
      _finish.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: LayoutBuilder(
      builder: (context, constraints) {
        // 기계는 폭을 기준으로 크기를 잡되 세로 여유를 넘지 않게 한다 —
        // 작은 화면에서도 넘치지 않게.
        final width = math.min(
          constraints.maxWidth,
          constraints.hasBoundedHeight
              ? constraints.maxHeight / _heightRatio
              : constraints.maxWidth,
        );
        return Center(
          child: SizedBox(
            width: width,
            height: width * _heightRatio,
            child: AnimatedBuilder(
              animation: Listenable.merge([_spin, _finish]),
              builder: (context, _) => CustomPaint(
                painter: const _MachineBodyPainter(),
                // 유리 반사는 공 위에 얹혀야 "유리 안쪽"으로 보인다.
                foregroundPainter: const _GlassGlarePainter(),
                child: _balls(width),
              ),
            ),
          ),
        );
      },
    ),
  );

  /// 유리통의 중심·반지름 비율은 껍데기를 그리는 [_MachineBodyPainter]와 공유한다.
  /// 한쪽만 바꾸면 공이 유리 밖으로 나간다.
  Widget _balls(double width) {
    final height = width * _heightRatio;
    final domeRadius = width * _domeRadiusRatio;
    final center = Offset(width / 2, height * _domeCenterYRatio);
    final chute = Offset(width / 2, height * _chuteYRatio);
    final finish = widget.phase == LaughDrawPhase.revealing
        ? _finish.value
        : 0.0;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var index = 0; index < _ballSpecs.length; index++)
          _ball(
            _ballSpecs[index],
            center: center,
            domeRadius: domeRadius,
            chute: chute,
            // 첫 번째 공이 당첨 공이다.
            finish: index == 0 ? finish : 0,
            settle: finish,
          ),
      ],
    );
  }

  Widget _ball(
    _BallSpec ball, {
    required Offset center,
    required double domeRadius,
    required Offset chute,
    required double finish,
    required double settle,
  }) {
    final size = domeRadius * ball.size;
    final offset = finish > 0
        ? _winnerOffset(ball, center, domeRadius, chute, finish)
        : _orbitOffset(ball, center, domeRadius, settle);
    return Positioned(
      left: offset.dx - size / 2,
      top: offset.dy - size / 2,
      child: Transform.rotate(
        angle: _spinning ? _spin.value * math.pi * 2 * ball.speed * 0.4 : 0,
        child: _BallDot(color: ball.color, size: size),
      ),
    );
  }

  /// 유리통 안에서 도는 자리.
  ///
  /// 공마다 시작 위상·회전 속도·궤도 반지름·방향이 조금씩 달라 같은 컨트롤러를
  /// 봐도 서로 다르게 움직인다. 멈춰 있을 때는 아래쪽에 쌓여 기다린다.
  Offset _orbitOffset(
    _BallSpec ball,
    Offset center,
    double domeRadius,
    double settle,
  ) {
    if (!_spinning) {
      return center + Offset(ball.restX * domeRadius, ball.restY * domeRadius);
    }
    final t = _spin.value;
    final angle =
        ball.phase * math.pi * 2 +
        t * math.pi * 2 * ball.speed * ball.direction;
    // 살짝 튀는 느낌: 궤도 반지름을 사인파로 흔든다.
    final bounce = 1 + 0.13 * math.sin((t * 2 + ball.phase) * math.pi * 2);
    // 마무리로 갈수록 궤도가 좁아지고 아래로 가라앉는다.
    final radius = domeRadius * ball.orbit * bounce * (1 - 0.32 * settle);
    return center +
        Offset(
          math.cos(angle) * radius,
          math.sin(angle) * radius * 0.84 + domeRadius * 0.26 * settle,
        );
  }

  /// 당첨 공: 돌던 자리 → 배출구 → 한 번 가볍게 튀고 받침대에 눕는다.
  Offset _winnerOffset(
    _BallSpec ball,
    Offset center,
    double domeRadius,
    Offset chute,
    double finish,
  ) {
    final angle = ball.phase * math.pi * 2 + _spinAtReveal * math.pi * 2;
    final radius = domeRadius * ball.orbit;
    final from =
        center +
        Offset(math.cos(angle) * radius, math.sin(angle) * radius * 0.84);
    final fall = Curves.easeInCubic.transform(finish.clamp(0.0, 1.0));
    var position = Offset.lerp(from, chute, fall)!;
    if (finish > 0.66) {
      final bounce = ((finish - 0.66) / 0.34).clamp(0.0, 1.0);
      position = position.translate(
        0,
        -math.sin(bounce * math.pi) * domeRadius * 0.24,
      );
    }
    return position;
  }

  /// 공 7개. 성능 부담을 줄이려 이 이상 늘리지 않는다(권장 5~8개).
  static const _ballSpecs = <_BallSpec>[
    // 첫 번째가 당첨 공이다. 제품 색(코랄)으로 눈에 먼저 들어오게 둔다.
    _BallSpec(AppColors.coral, 0.00, 0.60, 1.00, 1, 0.48, -0.36, 0.42),
    _BallSpec(AppColors.yellow, 0.15, 0.52, 1.32, -1, 0.42, 0.10, 0.46),
    _BallSpec(AppColors.sage, 0.30, 0.64, 0.86, 1, 0.44, -0.04, 0.28),
    _BallSpec(AppColors.pink, 0.44, 0.44, 1.14, -1, 0.40, 0.36, 0.38),
    _BallSpec(AppColors.greenCard, 0.59, 0.58, 0.96, 1, 0.46, -0.22, 0.14),
    _BallSpec(AppColors.coralDark, 0.73, 0.48, 1.22, -1, 0.38, 0.24, 0.16),
    _BallSpec(AppColors.yellowSoft, 0.87, 0.36, 1.06, 1, 0.36, 0.06, 0.02),
  ];
}

/// 기계 그림의 비율. 껍데기와 공이 같은 값을 봐야 한다.
const _heightRatio = 1.22;
const _domeRadiusRatio = 0.355;
const _domeCenterYRatio = 0.315;
const _chuteYRatio = 0.815;

/// 공 하나의 성격. 모두 상수라 매 프레임 새로 만들지 않는다.
class _BallSpec {
  const _BallSpec(
    this.color,
    this.phase,
    this.orbit,
    this.speed,
    this.direction,
    this.size,
    this.restX,
    this.restY,
  );

  final Color color;

  /// 시작 위상(0~1). 공들이 한 점에서 출발하지 않게 한다.
  final double phase;

  /// 궤도 반지름 배율(유리통 반지름 기준).
  final double orbit;
  final double speed;

  /// 회전 방향(+1/-1). 서로 반대로 돌면 훨씬 부산스럽게 보인다.
  final int direction;

  /// 공 지름 배율(유리통 반지름 기준).
  final double size;

  /// 멈춰 있을 때 쌓여 있는 자리.
  final double restX;
  final double restY;
}

/// 사탕처럼 광이 나는 공 하나.
class _BallDot extends StatelessWidget {
  const _BallDot({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      children: [
        // 몸통. 왼쪽 위에서 빛이 오는 것처럼 밝게 시작해 아래로 어두워진다.
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.38, -0.44),
              radius: 1.0,
              colors: [
                Color.lerp(color, Colors.white, 0.62)!,
                color,
                Color.lerp(color, const Color(0xFF8A5A44), 0.28)!,
              ],
              stops: const [0, 0.58, 1],
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.34),
                blurRadius: size * 0.2,
                offset: Offset(0, size * 0.1),
              ),
            ],
          ),
          child: const SizedBox.expand(),
        ),
        // 하이라이트 한 점. 플라스틱 사탕 느낌을 만드는 값싼 방법이다.
        Positioned(
          left: size * 0.2,
          top: size * 0.16,
          child: Container(
            width: size * 0.26,
            height: size * 0.2,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.all(Radius.elliptical(size, size)),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 기계 껍데기(유리통 안쪽·몸통·배출구). 공보다 **뒤에** 그린다.
class _MachineBodyPainter extends CustomPainter {
  const _MachineBodyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final domeRadius = width * _domeRadiusRatio;
    final domeCenter = Offset(width / 2, height * _domeCenterYRatio);
    final bodyTop = height * 0.575;

    // 바닥 그림자. 장난감이 바닥에 놓인 느낌을 준다.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(width / 2, height * 0.975),
        width: width * 0.68,
        height: height * 0.045,
      ),
      Paint()..color = const Color(0x146B4C2D),
    );

    // 몸통. 위가 살짝 좁은 사다리꼴 느낌으로 둥글게 깎는다.
    final body = RRect.fromRectAndCorners(
      Rect.fromLTRB(width * 0.155, bodyTop, width * 0.845, height * 0.965),
      topLeft: Radius.circular(width * 0.13),
      topRight: Radius.circular(width * 0.13),
      bottomLeft: Radius.circular(width * 0.19),
      bottomRight: Radius.circular(width * 0.19),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFC7AE), AppColors.coral, Color(0xFFE0664D)],
          stops: [0, 0.55, 1],
        ).createShader(body.outerRect),
    );
    // 몸통 위쪽 하이라이트.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          width * 0.22,
          bodyTop + height * 0.022,
          width * 0.2,
          height * 0.035,
        ),
        Radius.circular(height * 0.02),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.26),
    );

    // 유리통을 받치는 목(칼라).
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          width * 0.295,
          height * 0.525,
          width * 0.705,
          bodyTop + 8,
        ),
        Radius.circular(width * 0.06),
      ),
      Paint()..color = const Color(0xFFEE8B6F),
    );

    // 유리통 테두리(크림색 링).
    canvas.drawCircle(
      domeCenter,
      domeRadius + width * 0.022,
      Paint()..color = const Color(0xFFFFF1E4),
    );
    canvas.drawCircle(
      domeCenter,
      domeRadius + width * 0.022,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = AppColors.line,
    );

    // 유리 안쪽. 위는 맑고 아래는 살짝 그늘진다.
    canvas.drawCircle(
      domeCenter,
      domeRadius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.36, -0.5),
          radius: 1.08,
          colors: const [
            Color(0xFFFFFFFF),
            Color(0xFFFFF4E9),
            Color(0xFFFBE6D6),
          ],
          stops: const [0, 0.62, 1],
        ).createShader(Rect.fromCircle(center: domeCenter, radius: domeRadius)),
    );

    // 뚜껑과 그 위의 하트 손잡이.
    final lidCenter = Offset(
      width / 2,
      domeCenter.dy - domeRadius - height * 0.012,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: lidCenter,
          width: width * 0.28,
          height: height * 0.042,
        ),
        Radius.circular(height * 0.024),
      ),
      Paint()..color = AppColors.coral,
    );
    _drawHeart(
      canvas,
      Offset(width / 2, lidCenter.dy - height * 0.042),
      width * 0.075,
      Paint()..color = const Color(0xFFF79280),
    );

    // 배출구 받침 접시.
    final chute = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(width / 2, height * _chuteYRatio),
        width: width * 0.36,
        height: height * 0.125,
      ),
      Radius.circular(width * 0.06),
    );
    canvas.drawRRect(chute, Paint()..color = const Color(0xFFFFF6EC));
    canvas.drawRRect(
      chute,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = const Color(0x33B4553C),
    );

    // 손잡이(돌리는 다이얼).
    final knob = Offset(width * 0.265, height * 0.795);
    canvas.drawCircle(
      knob,
      width * 0.062,
      Paint()..color = const Color(0xFFFFE8B7),
    );
    canvas.drawCircle(
      knob,
      width * 0.062,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = const Color(0x33B4553C),
    );
    // 다이얼 홈.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: knob,
          width: width * 0.062,
          height: width * 0.014,
        ),
        Radius.circular(width * 0.01),
      ),
      Paint()..color = const Color(0xFFE3A94F),
    );
  }

  void _drawHeart(Canvas canvas, Offset center, double size, Paint paint) {
    final path = Path();
    final width = size;
    final height = size * 0.9;
    path.moveTo(center.dx, center.dy + height * 0.42);
    path.cubicTo(
      center.dx - width * 0.72,
      center.dy - height * 0.06,
      center.dx - width * 0.34,
      center.dy - height * 0.72,
      center.dx,
      center.dy - height * 0.24,
    );
    path.cubicTo(
      center.dx + width * 0.34,
      center.dy - height * 0.72,
      center.dx + width * 0.72,
      center.dy - height * 0.06,
      center.dx,
      center.dy + height * 0.42,
    );
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MachineBodyPainter oldDelegate) => false;
}

/// 유리 반사. 공보다 **앞에** 그려야 공이 유리 안에 든 것처럼 보인다.
class _GlassGlarePainter extends CustomPainter {
  const _GlassGlarePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final domeRadius = width * _domeRadiusRatio;
    final domeCenter = Offset(width / 2, height * _domeCenterYRatio);
    final circle = Rect.fromCircle(center: domeCenter, radius: domeRadius);

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    // 왼쪽 위 큰 반사.
    canvas.drawOval(
      Rect.fromCenter(
        center: domeCenter.translate(-domeRadius * 0.42, -domeRadius * 0.5),
        width: domeRadius * 0.62,
        height: domeRadius * 0.95,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );
    // 그 옆의 작은 반사.
    canvas.drawOval(
      Rect.fromCenter(
        center: domeCenter.translate(-domeRadius * 0.16, -domeRadius * 0.62),
        width: domeRadius * 0.2,
        height: domeRadius * 0.4,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.42),
    );
    // 아래쪽 그늘. 유리 두께가 느껴지게 한다.
    canvas.drawCircle(
      domeCenter.translate(0, domeRadius * 0.34),
      domeRadius * 0.95,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = domeRadius * 0.18
        ..color = const Color(0x14B4553C),
    );
    canvas.restore();

    // 유리 바깥 테두리.
    canvas.drawCircle(
      domeCenter,
      domeRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = const Color(0x40E0664D),
    );
  }

  @override
  bool shouldRepaint(_GlassGlarePainter oldDelegate) => false;
}
