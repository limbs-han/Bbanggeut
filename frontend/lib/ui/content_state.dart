import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/models.dart';

export '../core/models.dart' show CalendarSchedule, calendarScheduleEmojis;

/// 캘린더 일정 저장소. 서버 일정 CRUD(API-74~77)를 원본으로 쓰고,
/// 클라이언트가 연결되지 않은 상태(테스트·오프라인 폴백)에서는 메모리
/// 목록만 갱신한다. 서버 반영에 실패하면 예외를 그대로 올려 화면이
/// 사용자에게 알리게 한다.
class ContentState extends ChangeNotifier {
  ContentState([this._client]);

  static final ContentState instance = ContentState();

  ApiClient? _client;
  final List<CalendarSchedule> _schedules = [];
  bool _loaded = false;
  Future<void>? _loading;

  List<CalendarSchedule> get schedules => List.unmodifiable(_schedules);

  /// 서버 목록을 최초 1회 불러온다. 캘린더 진입 시 호출되며, 이미 불러왔거나
  /// 불러오는 중이면 그 결과를 같이 기다린다. 실패는 조용히 넘겨 다음 진입에서
  /// 다시 시도한다(캘린더 자체는 로컬 상태로도 뜬다).
  Future<void> ensureLoaded(ApiClient client) {
    _client = client;
    if (_loaded) return Future.value();
    return _loading ??= _load(client);
  }

  Future<void> _load(ApiClient client) async {
    try {
      final items = await client.listSchedules();
      _schedules
        ..clear()
        ..addAll(items);
      _loaded = true;
      notifyListeners();
    } on ApiFailure {
      // 오프라인이어도 화면은 뜬다.
    } finally {
      _loading = null;
    }
  }

  /// 생성 또는 수정. 서버가 준(또는 로컬 폴백의) 최종 일정을 반환한다.
  Future<CalendarSchedule> saveSchedule(
    CalendarSchedule schedule, {
    bool? isNew,
  }) async {
    final client = _client;
    final creating =
        isNew ?? _schedules.indexWhere((item) => item.id == schedule.id) < 0;
    var saved = schedule;
    if (client != null) {
      saved = creating
          ? await client.createSchedule(schedule)
          : await client.updateSchedule(schedule);
    }
    final index = _schedules.indexWhere(
      (item) => item.id == schedule.id || item.id == saved.id,
    );
    if (index < 0) {
      _schedules.add(saved);
    } else {
      _schedules[index] = saved;
    }
    notifyListeners();
    return saved;
  }

  Future<void> removeSchedule(String id) async {
    final client = _client;
    if (client != null) {
      await client.deleteSchedule(id);
    }
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
