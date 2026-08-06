/// "분석 중" 띠.
///
/// 분석이 도는 동안 AI 자동 컷·줌은 규칙만으로 돌고 만화는 프레임을 등분해
/// 뽑는다. 결과가 달라지는데 화면에 표시가 없으면 사용자는 그 결과를 "AI가 원래
/// 이 정도"로 받아들인다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/features/analysis/analysis_notice.dart';

void main() {
  Future<void> pump(WidgetTester tester, VideoAnalysis analysis) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnalysisNotice(analysis: analysis)),
        ),
      );

  testWidgets('분석한 적이 없으면 아무것도 그리지 않는다', (tester) async {
    await pump(tester, VideoAnalysis.none);

    expect(find.byKey(const ValueKey('analysis-running')), findsNothing);
    expect(find.byKey(const ValueKey('analysis-failed')), findsNothing);
  });

  /// 끝난 뒤에도 띠가 남으면 화면 위쪽을 영구히 잡아먹는다.
  testWidgets('분석이 끝나면 띠가 사라진다', (tester) async {
    await pump(tester, const VideoAnalysis(status: 'DONE', progress: 1));

    expect(find.byKey(const ValueKey('analysis-running')), findsNothing);
  });

  testWidgets('진행 중이면 단계와 진행률을 사람 말로 보여 준다', (tester) async {
    await pump(
      tester,
      const VideoAnalysis(status: 'RUNNING', stage: 'expression', progress: 0.35),
    );

    expect(find.byKey(const ValueKey('analysis-running')), findsOneWidget);
    expect(find.textContaining('표정을 보는 중'), findsOneWidget);
    expect(find.textContaining('35%'), findsOneWidget);
  });

  /// 진행률을 모르는 단계에서 0%를 보여 주면 멈춘 것처럼 보인다.
  testWidgets('진행률을 모르면 퍼센트를 붙이지 않는다', (tester) async {
    await pump(tester, const VideoAnalysis(status: 'RUNNING', stage: 'download'));

    expect(find.textContaining('영상을 가져오는 중'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  /// 워커가 단계를 하나 더 늘렸을 때 영문 코드를 그대로 보여 주면 안 된다.
  testWidgets('모르는 단계는 뭉뚱그린다', (tester) async {
    await pump(tester, const VideoAnalysis(status: 'RUNNING', stage: 'newthing'));

    expect(find.textContaining('분석하는 중'), findsOneWidget);
    expect(find.textContaining('newthing'), findsNothing);
  });

  /// 실패를 감추면 사용자가 끝나기를 영원히 기다린다.
  testWidgets('실패하면 사유 대신 다음에 무슨 일이 되는지 알린다', (tester) async {
    await pump(
      tester,
      const VideoAnalysis(status: 'FAILED', error: 'RuntimeError: 디코더'),
    );

    expect(find.byKey(const ValueKey('analysis-failed')), findsOneWidget);
    expect(find.textContaining('기본 규칙으로'), findsOneWidget);
  });
}
