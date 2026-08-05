import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/all_memories_screen.dart';

VideoMemory video({
  required String sourceType,
  String triggerType = 'LAUGHTER',
  List<String> eventTypes = const ['LAUGHTER'],
}) => VideoMemory(
  id: 'video-1',
  deviceId: 'device-1',
  triggerType: triggerType,
  eventTypes: eventTypes,
  sourceType: sourceType,
  title: '웃음이 담긴 순간',
  status: 'READY',
  favorite: false,
);

void main() {
  // 서버는 편집본 행에 원본의 trigger_type·event_types를 그대로 물려준다
  // (VideoMapper.insertEditOutput). 그래서 편집본도 LAUGHTER를 들고 있다 —
  // 이 픽스처가 바로 그 상태다.
  final captured = video(sourceType: 'IOT_CAPTURE');
  final edited = video(sourceType: 'EDIT_OUTPUT');

  test('편집본은 이벤트 종류가 LAUGHTER여도 웃음 감지에 나오지 않는다', () {
    expect(edited.hasEventType('LAUGHTER'), isTrue, reason: '물려받은 값 확인');
    expect(matchesMemoryCategory(edited, MemoryCategory.laughter), isFalse);
  });

  test('웃음 감지는 원본을 보여 준다', () {
    expect(matchesMemoryCategory(captured, MemoryCategory.laughter), isTrue);
  });

  test('편집 완료는 편집본만 보여 준다', () {
    expect(matchesMemoryCategory(edited, MemoryCategory.edited), isTrue);
    expect(matchesMemoryCategory(captured, MemoryCategory.edited), isFalse);
  });

  test('박수만 잡힌 원본도 웃음 감지에서 사라지지 않는다', () {
    // 이벤트 종류로 걸면 이 클립은 세 탭 어디에도 없다.
    final clap = video(
      sourceType: 'IOT_CAPTURE',
      triggerType: 'CLAP',
      eventTypes: const ['CLAP'],
    );
    expect(clap.hasEventType('LAUGHTER'), isFalse);
    expect(matchesMemoryCategory(clap, MemoryCategory.laughter), isTrue);
  });

  test('편집 중은 영상 행으로 판정하지 않는다', () {
    // 초안은 editor-api 목록에서 온다.
    expect(matchesMemoryCategory(captured, MemoryCategory.editing), isFalse);
    expect(matchesMemoryCategory(edited, MemoryCategory.editing), isFalse);
  });
}
