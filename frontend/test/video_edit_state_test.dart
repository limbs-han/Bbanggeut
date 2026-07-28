import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/video_edit_state.dart';

void main() {
  group('VideoEditState', () {
    test('keeps original aspect ratio until the user chooses 9:16', () {
      final state = VideoEditState(
        durationMs: 12 * 1000,
        originalAspectRatio: 16 / 9,
      );

      expect(state.previewAspectRatio, 16 / 9);
      expect(state.isShortForm, false);

      state.selectRatio(VideoEditRatio.shortForm);

      expect(state.previewAspectRatio, 9 / 16);
      expect(state.isShortForm, true);
    });

    test('clamps the trim range and keeps a minimum clip length', () {
      final state = VideoEditState(
        durationMs: 10 * 1000,
        originalAspectRatio: 1,
      );
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

    test('selecting a toolbar does not create a fake unsaved edit', () {
      final state = VideoEditState(
        durationMs: 10 * 1000,
        originalAspectRatio: 16 / 9,
      );

      for (final tool in ['caption', 'audio', 'effect', 'ar']) {
        state.selectTool(tool);
        expect(state.selectedTool, tool);
        expect(state.hasUnsavedChanges, isFalse);
      }
    });

    test('tracks local transforms and completed external edits', () {
      final state = VideoEditState(
        durationMs: 10 * 1000,
        originalAspectRatio: 16 / 9,
      );

      expect(state.hasTimelineOrRatioChanges, isFalse);
      state.selectRatio(VideoEditRatio.shortForm);
      expect(state.hasTimelineOrRatioChanges, isTrue);

      state.markSaved();
      expect(state.hasUnsavedChanges, isFalse);
      state.markExternalEditApplied();
      expect(state.hasUnsavedChanges, isTrue);
    });

    test('supports every ratio exposed by the editor sheet', () {
      final state = VideoEditState(
        durationMs: 10 * 1000,
        originalAspectRatio: 2,
      );

      final expectedRatios = {
        VideoEditRatio.original: 2.0,
        VideoEditRatio.shortForm: 9 / 16,
        VideoEditRatio.square: 1.0,
        VideoEditRatio.landscape: 16 / 9,
        VideoEditRatio.classic: 4 / 3,
        VideoEditRatio.portrait: 3 / 4,
      };

      for (final entry in expectedRatios.entries) {
        state.selectRatio(entry.key);
        expect(state.previewAspectRatio, entry.value);
      }
    });
  });
}
