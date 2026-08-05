import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/ui/live_screen.dart';

void main() {
  test('다른 화면이 홈을 덮으면 라이브를 놓는다', () {
    // 보이지 않는 스트림이 배터리와 데이터를 먹는다.
    expect(
      EmbeddedLivePlayer.shouldSuspend(
        wasActive: true,
        isActive: false,
        fullscreenOpen: false,
      ),
      isTrue,
    );
  });

  test('전체 화면이 떠 있는 동안은 놓지 않는다', () {
    // 전체 화면은 이 위젯의 플레이어를 그대로 받아 그린다. 여기서 놓으면
    // 전체 화면을 누른 순간 라이브가 끊긴다.
    expect(
      EmbeddedLivePlayer.shouldSuspend(
        wasActive: true,
        isActive: false,
        fullscreenOpen: true,
      ),
      isFalse,
    );
  });

  test('계속 활성이면 놓을 일이 없다', () {
    expect(
      EmbeddedLivePlayer.shouldSuspend(
        wasActive: true,
        isActive: true,
        fullscreenOpen: false,
      ),
      isFalse,
    );
  });

  test('이미 비활성이던 상태에서는 다시 놓지 않는다', () {
    expect(
      EmbeddedLivePlayer.shouldSuspend(
        wasActive: false,
        isActive: false,
        fullscreenOpen: false,
      ),
      isFalse,
    );
  });
}
