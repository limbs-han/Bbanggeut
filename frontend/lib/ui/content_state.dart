import 'package:flutter/foundation.dart';

class CalendarSchedule {
  const CalendarSchedule({
    required this.id,
    required this.title,
    required this.date,
    this.memo = '',
    this.yearly = false,
    this.emoji = '❤️',
  });

  final String id;
  final String title;
  final DateTime date;
  final String memo;
  final bool yearly;
  final String emoji;

  CalendarSchedule copyWith({
    String? title,
    DateTime? date,
    String? memo,
    bool? yearly,
    String? emoji,
  }) => CalendarSchedule(
    id: id,
    title: title ?? this.title,
    date: date ?? this.date,
    memo: memo ?? this.memo,
    yearly: yearly ?? this.yearly,
    emoji: emoji ?? this.emoji,
  );
}

const calendarScheduleEmojis = ['❤️', '🎂', '🍚', '☎️', '📷', '⭐', '🎁', '🌸'];

/// 일정 API가 준비되기 전 화면 간 상태를 공유하는 임시 저장소입니다.
/// 앱을 다시 시작하면 사라집니다. 알림 목록/읽음 처리는 이미
/// `/api/notifications`로 옮겨 갔고, 여기 남은 것은 일정뿐입니다.
///
/// TODO(content-api): 백엔드에 일정 CRUD API가 생기면 교체합니다(2026-08-03
/// 기준 서버에 일정/캘린더 엔드포인트 없음).
class ContentState extends ChangeNotifier {
  ContentState._();

  static final ContentState instance = ContentState._();

  final List<CalendarSchedule> _schedules = [];

  List<CalendarSchedule> get schedules => List.unmodifiable(_schedules);

  void saveSchedule(CalendarSchedule schedule) {
    final index = _schedules.indexWhere((item) => item.id == schedule.id);
    if (index < 0) {
      _schedules.add(schedule);
    } else {
      _schedules[index] = schedule;
    }
    notifyListeners();
  }

  void removeSchedule(String id) {
    _schedules.removeWhere((item) => item.id == id);
    notifyListeners();
  }
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

int calendarDayDifference(DateTime target, {DateTime? from}) =>
    dateOnly(target).difference(dateOnly(from ?? DateTime.now())).inDays;

String dDayLabel(DateTime target, {DateTime? from}) {
  final difference = calendarDayDifference(target, from: from);
  if (difference == 0) return 'D-Day';
  return difference > 0 ? 'D-$difference' : 'D+${difference.abs()}';
}

DateTime nextYearlyOccurrence(DateTime date, {DateTime? from}) {
  final today = dateOnly(from ?? DateTime.now());
  var candidate = DateTime(today.year, date.month, date.day);
  if (candidate.isBefore(today)) {
    candidate = DateTime(today.year + 1, date.month, date.day);
  }
  return candidate;
}
