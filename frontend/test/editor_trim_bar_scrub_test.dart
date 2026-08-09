/// 재생 봉(노란 구간 안의 흰 막대)을 끌어 옮기는 동작.
///
/// 노란 창 안쪽에는 "구간을 통째로 옮기는" 층이 깔린다. 그 층이 가로 끌기를
/// 먹어 버리면 재생 봉은 손가락을 따라오지 못하고, 손을 떼면 제자리로
/// 돌아온 것처럼 보인다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_trim_bar.dart';

void main() {
  /// 띠 하나. 창은 2~6초, 재생 봉은 그 가운데(4초)에 있다.
  Widget bar({
    required void Function(int) onScrub,
    required void Function(int startMs, int endMs, bool startHandle)
    onTrimChanged,
    bool windowSlidable = true,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 64,
          child: TrimRangeBar(
            sourceDurationMs: 20000,
            startMs: 2000,
            endMs: 6000,
            playheadSourceMs: 4000,
            thumbnails: const [],
            minimumDurationMs: 200,
            windowSlidable: windowSlidable,
            onTrimChanged: onTrimChanged,
            onTrimCommitted: () {},
            onScrub: onScrub,
          ),
        ),
      ),
    ),
  );

  testWidgets('노란 구간 안에서 재생 봉을 끌면 재생 위치가 따라온다', (tester) async {
    final scrubbed = <int>[];
    final trimmed = <String>[];
    await tester.pumpWidget(
      bar(
        onScrub: scrubbed.add,
        onTrimChanged: (startMs, endMs, _) => trimmed.add('$startMs-$endMs'),
      ),
    );

    // 재생 봉이 있는 자리(창 가운데)에서 오른쪽으로 끈다.
    final playhead = tester.getCenter(find.byKey(const Key('editor-playhead')));
    await tester.dragFrom(playhead, const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(
      scrubbed,
      isNotEmpty,
      reason: '재생 봉을 끌었는데 재생 위치가 한 번도 안 바뀌었다',
    );
    expect(scrubbed.last, greaterThan(4000), reason: '오른쪽으로 끌었으면 시각도 커져야 한다');
    expect(trimmed, isEmpty, reason: '재생 봉을 끌었는데 구간이 옮겨졌다');
  });

  testWidgets('노란 구간의 빈 곳을 끌면 구간이 통째로 옮겨진다', (tester) async {
    final scrubbed = <int>[];
    final trimmed = <String>[];
    await tester.pumpWidget(
      bar(
        onScrub: scrubbed.add,
        onTrimChanged: (startMs, endMs, _) => trimmed.add('$startMs-$endMs'),
      ),
    );

    // 재생 봉에서 충분히 떨어진 창 안쪽(왼쪽 끝 근처)을 끈다.
    final slide = tester.getRect(
      find.byKey(const Key('editor-trim-window-slide')),
    );
    await tester.dragFrom(
      Offset(slide.left + 12, slide.center.dy),
      const Offset(30, 0),
    );
    await tester.pumpAndSettle();

    expect(trimmed, isNotEmpty, reason: '창 안쪽을 끌었는데 구간이 안 옮겨졌다');
  });
}
