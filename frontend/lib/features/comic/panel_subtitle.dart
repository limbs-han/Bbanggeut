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

/// 자막 띠를 칸 아래쪽에 둔다. y는 -1이 위, 1이 아래다.
const _subtitleY = 0.82;

Alignment subtitleAlignment(int cutIndex) {
  final right = cutIndex % 2 == 1;
  final bottom = cutIndex >= 2;
  return Alignment(
    right ? 0.5 : -0.5,
    bottom ? _subtitleY : _subtitleY - 1,
  );
}

class ComicCanvas extends StatelessWidget {
  const ComicCanvas({super.key, required this.image, required this.cuts});

  final Uint8List image;
  final List<ComicCut> cuts;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(image, fit: BoxFit.contain),
        for (var index = 0; index < cuts.length; index++)
          if (cuts[index].dialogue case final line?)
            Align(
              alignment: subtitleAlignment(index),
              child: FractionallySizedBox(
                widthFactor: 0.44,
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
      ],
    ),
  );
}
