import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:william_james_app/ui/all_memories_screen.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ko'));

  // 완성본 업로드는 OS 백그라운드 작업이 하고 진행 상황은 상단 알림으로 나간다.
  // 알림을 껐거나 권한을 주지 않은 기기에서는 그 알림이 오지 않으므로, 목록
  // 줄이 진행 상황을 아는 유일한 단서가 된다.
  group('편집 목록 상태 문구', () {
    final savedAt = DateTime(2026, 8, 4, 21, 5);

    test('올라가는 중인 완성본은 올리는 중이라고 알려 준다', () {
      expect(
        editorEntrySubtitle(
          isDraft: false,
          uploading: true,
          failed: false,
          savedAt: savedAt,
        ),
        '8월 4일 21:05 서버에 올리는 중',
      );
    });

    test('업로드가 끝난 완성본은 편집 완료로 보여 준다', () {
      expect(
        editorEntrySubtitle(
          isDraft: false,
          uploading: false,
          failed: false,
          savedAt: savedAt,
        ),
        '8월 4일 21:05 편집 완료',
      );
    });

    // 실패한 줄이 목록에서 조용히 사라지면 사용자는 편집본이 어디로 갔는지
    // 알 수 없다. 남겨서 다시 저장하라고 말해 준다.
    test('업로드가 실패한 완성본은 다시 저장하라고 말해 준다', () {
      expect(
        editorEntrySubtitle(
          isDraft: false,
          uploading: false,
          failed: true,
          savedAt: savedAt,
        ),
        '8월 4일 21:05 업로드 실패 — 다시 저장해 주세요',
      );
    });

    test('초안은 업로드 상태와 무관하게 이어서 편집한다고 알려 준다', () {
      expect(
        editorEntrySubtitle(
          isDraft: true,
          uploading: false,
          failed: false,
          savedAt: savedAt,
        ),
        '8월 4일 21:05 저장한 초안',
      );
      expect(
        editorEntrySubtitle(
          isDraft: true,
          uploading: false,
          failed: false,
          savedAt: null,
        ),
        '이어서 편집할 수 있어요',
      );
    });
  });
}
