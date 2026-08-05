import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/widgets.dart';

final _at = DateTime(2026, 8, 5, 9, 27);

/// 요일은 달력이 정하는 값이라 실제 형식기에서 받아 쓴다. 손으로 박으면 날짜를
/// 바꿀 때마다 요일까지 다시 계산해야 한다.
String get _weekday => DateFormat('E', 'ko').format(_at);

VideoMemory video({
  required String title,
  String triggerType = 'LAUGHTER',
  List<String> eventTypes = const [],
  DateTime? capturedStartAt,
}) => VideoMemory(
  id: 'video-1',
  deviceId: 'device-1',
  triggerType: triggerType,
  eventTypes: eventTypes,
  title: title,
  status: 'READY',
  favorite: false,
  capturedStartAt: capturedStartAt,
);

void main() {
  setUpAll(() => initializeDateFormatting('ko'));

  test('기기 기본 제목은 날짜·시각·종류를 담은 제목으로 바뀐다', () {
    // 웃음 클립 스무 개가 모두 "웃음이 담긴 순간"이면 목록에서 구분할 수 없다.
    final title = videoDisplayTitle(
      video(title: '웃음이 담긴 순간', capturedStartAt: _at),
    );

    expect(title, '8월 5일($_weekday) 오전 9:27 · 웃음');
  });

  test('사용자가 붙인 이름은 건드리지 않는다', () {
    // 제목은 상세 화면에서 편집할 수 있다. 자동 생성이 덮으면 지은 이름이 사라진다.
    final title = videoDisplayTitle(
      video(title: '할머니 생신날', capturedStartAt: _at),
    );

    expect(title, '할머니 생신날');
  });

  test('여러 종류가 함께 탐지되면 나란히 적는다', () {
    final title = videoDisplayTitle(
      video(
        title: '웃음과 박수가 함께 포착됐어요',
        eventTypes: const ['LAUGHTER', 'CLAP'],
        capturedStartAt: _at,
      ),
    );

    expect(title, '8월 5일($_weekday) 오전 9:27 · 웃음·박수');
  });

  test('날짜가 화면 맥락인 자리에서는 시각과 종류만 적는다', () {
    final title = videoDisplayTitle(
      video(title: '박수가 시작된 순간', triggerType: 'CLAP', capturedStartAt: _at),
      includeDate: false,
    );

    expect(title, '오전 9:27 · 박수');
  });

  test('시간 정보가 없으면 종류만 적는다', () {
    final title = videoDisplayTitle(
      video(title: '카메라를 부른 순간', triggerType: 'WAKE_WORD'),
    );

    expect(title, '호출');
  });
}
