import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/ui/content_state.dart';

void main() {
  group('콘텐츠 날짜 계산', () {
    test('시간대와 관계없이 날짜 기준으로 디데이를 계산한다', () {
      final from = DateTime(2026, 7, 28, 23, 59);

      expect(calendarDayDifference(DateTime(2026, 7, 31, 0, 1), from: from), 3);
      expect(dDayLabel(DateTime(2026, 7, 28), from: from), 'D-Day');
      expect(dDayLabel(DateTime(2026, 7, 26), from: from), 'D+2');
    });

    test('매년 반복 일정의 다음 발생일을 계산한다', () {
      expect(
        nextYearlyOccurrence(
          DateTime(1990, 7, 30),
          from: DateTime(2026, 7, 28),
        ),
        DateTime(2026, 7, 30),
      );
      expect(
        nextYearlyOccurrence(
          DateTime(1990, 7, 20),
          from: DateTime(2026, 7, 28),
        ),
        DateTime(2027, 7, 20),
      );
    });
  });
}
