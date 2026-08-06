/// 2x2 만화 그림 위에 대사를 영화 자막처럼 얹는다.
///
/// **왜 말풍선이 아닌가**: 생성 모델에게 말풍선을 그리지 말라고 요청한다. 말풍선
/// 자리가 있으면 모델이 거기에 글자를 넣으려 하고(PC 시험에서 "CRASH"가 박혔다),
/// 앱이 얹는 글자와 스타일도 섞인다.
///
/// **칸 대응은 읽는 순서와 같다** — 0 왼쪽 위, 1 오른쪽 위, 2 왼쪽 아래, 3 오른쪽
/// 아래. 그림이 2x2 격자로 나온다는 전제에 기대고 있다(설계의 천장).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'comic_script.dart';

/// 자막 띠를 칸 아래쪽에 둔다. y는 -1이 위, 1이 아래다. 칸 바닥에 딱 붙이지 않는
/// 이유는 컷 사이 흰 여백과 검은 테두리를 밟으면 글자가 테두리에 걸쳐 읽기 나쁘기
/// 때문이다.
const _subtitleY = 0.82;

/// 띠 폭은 칸 폭의 88%. 남는 12%가 좌우 여백이라 글자가 컷 테두리에 닿지 않는다.
/// 그림 전체 폭으로 치면 44%다.
const _subtitleWidth = 0.88;

/// 띠는 **자기 칸 안에서** 가로 가운데, 아래쪽이다.
///
/// **왜 x가 0인가**: [Align]은 자식을 `부모 폭 − 자식 폭` 범위에서 움직인다(부모 폭
/// 기준이 아니다). 그림 전체를 부모로 두고 칸 중심을 x로 적으면 띠 폭만큼 안쪽으로
/// 밀려난다 — 예전에 x=±0.5로 두었더니 두 띠가 가운데 여백을 넘어 서로 겹쳤고,
/// 0컷 대사가 1컷 그림 위에 얹혔다. 칸을 먼저 잘라내고 그 안에서 가운데를 쓰면
/// 폭과 무관하게 정확하다. 이 구조를 "간단하게" 되돌리면 그 겹침이 돌아온다.
const _bandAlignment = Alignment(0, _subtitleY);

/// 컷 번호 → 그림에서 그 컷이 놓인 칸. 읽는 순서와 같다(0 왼쪽 위, 1 오른쪽 위,
/// 2 왼쪽 아래, 3 오른쪽 아래). 대응이 틀리면 3컷 대사가 1컷에 붙는다.
Alignment panelAlignment(int cutIndex) =>
    Alignment(cutIndex % 2 == 1 ? 1 : -1, cutIndex >= 2 ? 1 : -1);

/// 만화 바깥 테두리의 두께. 그림 한 변에 대한 비율이다.
///
/// **왜 앱이 그리나**: 예전에는 모델이 2x2 격자 바깥에 흰 테두리를 함께 그렸고,
/// 그것이 "만화답게" 보이게 하는 요소였다. 그런데 앱은 칸을 그림의 수학적
/// 4등분으로 잡고 자막을 앉히므로, 그림 안에 테두리가 있으면 칸 중심이 어긋난다
/// — 실측(1024px 만화)에서 사면 40~42px이라 왼쪽 칸 중심이 16px 밀렸다. 그래서
/// 서버가 받은 그림에서 테두리를 잘라낸다(`comic.normalize_square_image`).
///
/// 잘라내고 나니 이번에는 만화 느낌이 사라졌다. 둘 다 가지려면 **테두리를 그림
/// 밖에 두면 된다** — 자막 계산은 그림만 보고, 테두리는 그 바깥을 감싼다.
/// 모델이 그리던 것보다 나은 점도 있다: 모델의 테두리는 40·41·42·42로 사면이
/// 제각각이었는데 이것은 늘 같다.
///
/// 4%는 잘라낸 두께(1024px에 40~42px)를 그대로 되살린 값이다.
const comicFrameRatio = 0.04;

class ComicCanvas extends StatelessWidget {
  const ComicCanvas({super.key, required this.image, required this.cuts});

  final Uint8List image;
  final List<ComicCut> cuts;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    // 흰 테두리는 **그림 밖**이다. 안쪽(그림+자막)만 정사각으로 남기므로 칸을
    // 4등분하는 아래 계산이 테두리 두께와 무관하다 — [comicFrameRatio] 참고.
    child: ColoredBox(
      color: Colors.white,
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 1 - comicFrameRatio * 2,
          heightFactor: 1 - comicFrameRatio * 2,
          child: _panels(),
        ),
      ),
    ),
  );

  Widget _panels() => Stack(
    fit: StackFit.expand,
    children: [
      Image.memory(image, fit: BoxFit.contain),
      for (var index = 0; index < cuts.length; index++)
        if (cuts[index].dialogue case final line?)
          // 칸(그림의 1/4)을 먼저 잘라내고 그 안에서만 띠를 앉힌다 —
          // _bandAlignment 주석의 이유로 칸 밖 좌표를 쓰지 않는다.
          FractionallySizedBox(
            widthFactor: 0.5,
            heightFactor: 0.5,
            alignment: panelAlignment(index),
            child: Align(
              alignment: _bandAlignment,
              child: FractionallySizedBox(
                widthFactor: _subtitleWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      // 영화 자막에서 화자가 바뀜을 나타내는 관례다.
                      '- $line',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    ],
  );
}
