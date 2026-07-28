import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/video_edit_state.dart';

void main() {
  group('VideoEditState', () {
    test('keeps original aspect ratio until the user chooses 9:16', () {
      final state = VideoEditState(durationMs: 12 * 1000, originalAspectRatio: 16 / 9);

      expect(state.previewAspectRatio, 16 / 9);
      expect(state.isShortForm, false);

      state.selectRatio(VideoEditRatio.shortForm);

      expect(state.previewAspectRatio, 9 / 16);
      expect(state.isShortForm, true);
    });

    test('clamps the trim range and keeps a minimum clip length', () {
      final state = VideoEditState(durationMs: 10 * 1000, originalAspectRatio: 1);
      state.updateTrimRange(startMs: 2000, endMs: 8000);

      expect(state.startMs, 2000);
      expect(state.endMs, 8000);

      state.updateTrimRange(startMs: 9000, endMs: 10000);

      expect(state.startMs, 9000);
      expect(state.endMs, 10000);

      state.updateTrimRange(startMs: 9500, endMs: 9600);

      expect(state.startMs, 9500);
      expect(state.endMs, 9600);
    });
  });
}
