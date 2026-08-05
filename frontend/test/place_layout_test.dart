import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';

void main() {
  test('서버 배치를 읽어 장소·기기 배정·내 순서로 나눈다', () {
    final layout = PlaceLayout.fromJson({
      'places': ['거실', '안방'],
      'devicePlaces': {'device-1': '거실', 'device-2': '안방'},
      'deviceOrder': ['device-2', 'device-1'],
    });

    expect(layout.places, ['거실', '안방']);
    expect(layout.devicePlaces['device-1'], '거실');
    expect(layout.deviceOrder, ['device-2', 'device-1']);
    expect(layout.isEmpty, isFalse);
  });

  test('아직 아무 배치도 없는 금고는 비어 있다고 본다', () {
    // 이 판정으로 이 폰의 로컬 배치를 한 번 올릴지 정한다 — 그냥 덮으면
    // 서버화 이전에 각자 정리해 둔 배치가 기본값으로 초기화된다.
    final layout = PlaceLayout.fromJson({
      'places': <String>[],
      'devicePlaces': <String, String>{},
      'deviceOrder': <String>[],
    });

    expect(layout.isEmpty, isTrue);
  });

  test('필드가 빠진 응답도 빈 배치로 읽는다', () {
    final layout = PlaceLayout.fromJson({});

    expect(layout.places, isEmpty);
    expect(layout.devicePlaces, isEmpty);
    expect(layout.deviceOrder, isEmpty);
    expect(layout.isEmpty, isTrue);
  });
}
