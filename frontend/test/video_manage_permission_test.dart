import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/widgets.dart';

VideoMemory video({required String sourceType}) => VideoMemory(
  id: 'video-1',
  deviceId: 'device-1',
  triggerType: 'LAUGHTER',
  sourceType: sourceType,
  title: '웃음이 담긴 순간',
  status: 'READY',
  favorite: false,
);

void main() {
  final captured = video(sourceType: 'IOT_CAPTURE');
  final edited = video(sourceType: 'EDIT_OUTPUT');

  test('원본 영상은 OWNER만 제목을 바꾸고 지운다', () {
    // 기기가 담아 온 원본은 가족 공동의 기록이다.
    expect(canManageVideo(captured, isOwner: true), isTrue);
    expect(canManageVideo(captured, isOwner: false), isFalse);
  });

  test('편집본은 구성원에게도 버튼을 띄운다', () {
    // 만든 사람인지는 서버만 안다 — 남의 편집본이면 서버가 거절한다.
    expect(canManageVideo(edited, isOwner: false), isTrue);
    expect(canManageVideo(edited, isOwner: true), isTrue);
  });
}
