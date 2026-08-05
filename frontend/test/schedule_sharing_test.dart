import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';

CalendarSchedule schedule({String? authorId}) => CalendarSchedule(
  id: 'schedule-1',
  title: '결혼기념일',
  date: DateTime(2026, 5, 2),
  authorId: authorId,
  authorName: '엄마',
);

void main() {
  test('내가 적은 일정은 고칠 수 있다', () {
    expect(
      schedule(authorId: 'me').canManage(myUserId: 'me', isOwner: false),
      isTrue,
    );
  });

  test('남이 적은 일정은 구성원이 고칠 수 없다', () {
    // 가족이 함께 보는 목록이지만 남의 일정을 대신 고치지는 않는다.
    expect(
      schedule(authorId: 'mom').canManage(myUserId: 'me', isOwner: false),
      isFalse,
    );
  });

  test('OWNER는 남이 적은 일정도 고칠 수 있다', () {
    expect(
      schedule(authorId: 'mom').canManage(myUserId: 'me', isOwner: true),
      isTrue,
    );
  });

  test('작성자를 모르는 일정은 구성원이 건드리지 않는다', () {
    // 구버전 서버 응답에는 authorId가 없다 — 그때는 OWNER만 손댄다.
    expect(schedule().canManage(myUserId: 'me', isOwner: false), isFalse);
    expect(schedule().canManage(myUserId: 'me', isOwner: true), isTrue);
  });

  test('새 일정은 금고 id를 함께 보낸다', () {
    // 서버는 어느 가족의 캘린더인지 알아야 한다.
    final body = CalendarSchedule(
      id: 'temp',
      title: '생일',
      date: DateTime(2026, 9, 1),
      vaultId: 'vault-1',
    ).toJson();

    expect(body['vaultId'], 'vault-1');
  });

  test('금고를 모르면 vaultId를 아예 보내지 않는다', () {
    // 서버가 사용자의 금고가 하나일 때 알아서 정한다.
    final body = CalendarSchedule(
      id: 'temp',
      title: '생일',
      date: DateTime(2026, 9, 1),
    ).toJson();

    expect(body.containsKey('vaultId'), isFalse);
  });
}
