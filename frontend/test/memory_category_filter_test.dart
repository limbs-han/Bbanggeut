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

  test('만화는 영상 행으로 판정하지 않는다', () {
    // 금고 만화 목록(GET /api/vaults/{id}/comics)으로 따로 그린다. 영상 행에는
    // 만화 여부가 없으므로 여기서 참을 돌려주면 원본이 만화 탭에 다 나온다.
    expect(matchesMemoryCategory(captured, MemoryCategory.comic), isFalse);
    expect(matchesMemoryCategory(edited, MemoryCategory.comic), isFalse);
  });

  // '편집 중' 탭을 없앴다. 초안이 있는 영상은 결국 '웃음 감지'에 있는 그
  // 영상이라, 탭을 따로 두면 같은 영상이 두 군데 나오고 사용자가 어느 쪽으로
  // 들어갈지 골라야 했다. 이제 카드에 배지로 알린다.
  test('카테고리는 셋이다 — 웃음 감지·편집 완료·만화', () {
    expect(MemoryCategory.values, hasLength(3));
    expect(
      MemoryCategory.values,
      containsAll(<MemoryCategory>[
        MemoryCategory.laughter,
        MemoryCategory.edited,
        MemoryCategory.comic,
      ]),
    );
  });
}
